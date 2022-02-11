(* virt-v2v
 * Copyright (C) 2009-2021 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

open Printf
open Unix

open Std_utils
open Tools_utils
open Common_gettext.Gettext

open Types
open Utils

open Output

module RHVUpload = struct
  type poptions = string * string * string * string * string *
                  string option * string option * bool * bool *
                  string list option

  type t = int64 list * string list * string list *
           Python_script.script * Python_script.script *
           JSON.field list * string option * string option *
           string option * string * int list ref

  let to_string options =
    "-o rhv-upload" ^
      (match options.output_conn with
       | Some oc -> " -oc " ^ oc
       | None -> "") ^
      (match options.output_storage with
       | Some os -> " -os " ^ os
       | None -> "")

  let query_output_options () =
    printf (f_"Output options (-oo) which can be used with -o rhv-upload:

  -oo rhv-cafile=CA.PEM           Set ‘ca.pem’ certificate bundle filename.
  -oo rhv-cluster=CLUSTERNAME     Set RHV cluster name.
  -oo rhv-direct[=true|false]     Use direct transfer mode (default: false).
  -oo rhv-verifypeer[=true|false] Verify server identity (default: false).

You can override the UUIDs of the disks, instead of using autogenerated UUIDs
after their uploads (if you do, you must supply one for each disk):

  -oo rhv-disk-uuid=UUID          Disk UUID
")

  let rec parse_options options source =
    let output_conn =
      match options.output_conn with
      | None ->
         error (f_"-o rhv-upload: use ‘-oc’ to point to the oVirt or RHV server REST API URL, which is usually https://servername/ovirt-engine/api")
      | Some oc -> oc in
    (* In theory we could make the password optional in future. *)
    let output_password =
      match options.output_password with
      | None ->
         error (f_"-o rhv-upload: output password file was not specified, use ‘-op’ to point to a file which contains the password used to connect to the oVirt or RHV server")
      | Some op -> op in
    let output_storage =
      match options.output_storage with
      | None ->
         error (f_"-o rhv-upload: output storage was not specified, use ‘-os’");
      | Some os -> os in

    let rhv_cafile = ref None in
    let rhv_cluster = ref None in
    let rhv_direct = ref false in
    let rhv_verifypeer = ref false in
    let rhv_disk_uuids = ref None in

    List.iter (
      function
      | "rhv-cafile", v ->
         if !rhv_cafile <> None then
           error (f_"-o rhv-upload: -oo rhv-cafile set more than once");
         rhv_cafile := Some v
      | "rhv-cluster", v ->
         if !rhv_cluster <> None then
           error (f_"-o rhv-upload: -oo rhv-cluster set more than once");
         rhv_cluster := Some v
      | "rhv-direct", "" -> rhv_direct := true
      | "rhv-direct", v -> rhv_direct := bool_of_string v
      | "rhv-verifypeer", "" -> rhv_verifypeer := true
      | "rhv-verifypeer", v -> rhv_verifypeer := bool_of_string v
      | "rhv-disk-uuid", v ->
         if not (is_nonnil_uuid v) then
           error (f_"-o rhv-upload: invalid UUID for -oo rhv-disk-uuid");
         rhv_disk_uuids := Some (v :: (Option.default [] !rhv_disk_uuids))
      | k, _ ->
         error (f_"-o rhv-upload: unknown output option ‘-oo %s’") k
    ) options.output_options;

    let rhv_cafile = !rhv_cafile in
    let rhv_cluster = !rhv_cluster in
    let rhv_direct = !rhv_direct in
    let rhv_verifypeer = !rhv_verifypeer in
    let rhv_disk_uuids = Option.map List.rev !rhv_disk_uuids in

    let output_name = Option.default source.s_name options.output_name in

    (output_conn, options.output_format,
     output_password, output_name, output_storage,
     rhv_cafile, rhv_cluster, rhv_direct,
     rhv_verifypeer, rhv_disk_uuids)

  and is_nonnil_uuid uuid =
    let nil_uuid = "00000000-0000-0000-0000-000000000000" in
    let rex_uuid = lazy (
      let hex = "[a-fA-F0-9]" in
      let str = sprintf "^%s{8}-%s{4}-%s{4}-%s{4}-%s{12}$" hex hex hex hex hex in
      PCRE.compile str
    ) in
    if uuid = nil_uuid then false
    else PCRE.matches (Lazy.force rex_uuid) uuid

  let rec setup dir options source =
    let disks = get_disks dir in
    let output_conn, output_format,
        output_password, output_name, output_storage,
        rhv_cafile, rhv_cluster, rhv_direct,
        rhv_verifypeer, rhv_disk_uuids = options in

    (* We need nbdkit >= 1.22 for API_VERSION 2 and parallel threading model
     * in the python plugin.
     *)
    let nbdkit_min_version = (1, 22, 0) in
    let nbdkit_min_version_string = "1.22.0" in

    (* Check that the 'ovirtsdk4' Python module is available. *)
    let error_unless_ovirtsdk4_module_available () =
      let res = run_command [ Python_script.python; "-c";
                              "import ovirtsdk4" ] in
      if res <> 0 then
        error (f_"the Python module ‘ovirtsdk4’ could not be loaded, is it installed?  See previous messages for problems.")
    in

    (* Check that nbdkit is available and new enough. *)
    let error_unless_nbdkit_working () =
      if not (Nbdkit.is_installed ()) then
        error (f_"nbdkit is not installed or not working.  It is required to use ‘-o rhv-upload’.  See the virt-v2v-output-rhv(1) manual.")
    in

    let error_unless_nbdkit_min_version config =
      let version = Nbdkit.version config in
      if version < nbdkit_min_version then
        error (f_"nbdkit is not new enough, you need to upgrade to nbdkit ≥ %s")
          nbdkit_min_version_string
    in

    (* Check that the python3 plugin is installed and working
     * and can load the plugin script.
     *)
    let error_unless_nbdkit_python_plugin_working plugin_script =
      let cmd = sprintf "nbdkit python %s --dump-plugin >/dev/null"
                  (quote (Python_script.path plugin_script)) in
      debug "%s" cmd;
      if Sys.command cmd <> 0 then
        error (f_"nbdkit python plugin is not installed or not working.  It is required if you want to use ‘-o rhv-upload’.

See also the virt-v2v-output-rhv(1) manual.");
    in

    (* Check that nbdkit was compiled with SELinux support (for the
     * --selinux-label option).
     *)
    let error_unless_nbdkit_compiled_with_selinux config =
      if have_selinux then (
        let selinux = try List.assoc "selinux" config with Not_found -> "no" in
        if selinux = "no" then
          error (f_"nbdkit was compiled without SELinux support.  You will have to recompile nbdkit with libselinux-devel installed, or else set SELinux to Permissive mode while doing the conversion.")
      )
    in

    Python_script.error_unless_python_interpreter_found ();
    error_unless_ovirtsdk4_module_available ();
    error_unless_nbdkit_working ();
    let config = Nbdkit.config () in
    error_unless_nbdkit_min_version config;
    error_unless_nbdkit_compiled_with_selinux config;

    (* Python code. *)
    let precheck_script =
      Python_script.create ~name:"rhv-upload-precheck.py"
        Output_rhv_upload_precheck_source.code in
    let vmcheck_script =
      Python_script.create ~name:"rhv-upload-vmcheck.py"
        Output_rhv_upload_vmcheck_source.code in
    let plugin_script =
      Python_script.create ~name:"rhv-upload-plugin.py"
        Output_rhv_upload_plugin_source.code in
    let transfer_script =
      Python_script.create ~name:"rhv-upload-transfer.py"
        Output_rhv_upload_transfer_source.code in
    let finalize_script =
      Python_script.create ~name:"rhv-upload-finalize.py"
        Output_rhv_upload_finalize_source.code in
    let cancel_script =
      Python_script.create ~name:"rhv-upload-cancel.py"
        Output_rhv_upload_cancel_source.code in
    let createvm_script =
      Python_script.create ~name:"rhv-upload-createvm.py"
        Output_rhv_upload_createvm_source.code in

    error_unless_nbdkit_python_plugin_working plugin_script;

    (* JSON parameters which are invariant between disks. *)
    let json_params = [
      "verbose", JSON.Bool (verbose ());

      "output_conn", JSON.String output_conn;
      "output_password", JSON.String output_password;
      "output_storage", JSON.String output_storage;
      "rhv_cafile", json_optstring rhv_cafile;
      "rhv_cluster", JSON.String (Option.default "Default" rhv_cluster);
      "rhv_direct", JSON.Bool rhv_direct;

      (* The 'Insecure' flag seems to be a number with various possible
       * meanings, however we just set it to True/False.
       *
       * https://github.com/oVirt/ovirt-engine-sdk/blob/19aa7070b80e60a4cfd910448287aecf9083acbe/sdk/lib/ovirtsdk4/__init__.py#L395
       *)
      "insecure", JSON.Bool (not rhv_verifypeer);
    ] in

    (* nbdkit command line which is invariant between disks. *)
    let cmd = Nbdkit.create "python" in
    Nbdkit.add_arg cmd "script" (Python_script.path plugin_script);

    (* Match number of parallel coroutines in qemu-img *)
    Nbdkit.set_threads cmd 8;

    (* Python code prechecks. *)
    let json_params = match rhv_disk_uuids with
      | None -> json_params
      | Some uuids ->
         let ids = List.map (fun uuid -> JSON.String uuid) uuids in
         ("rhv_disk_uuids", JSON.List ids) :: json_params
    in
    let precheck_json = dir // "v2vprecheck.json" in
    let fd = Unix.openfile precheck_json [O_WRONLY; O_CREAT] 0o600 in
    if Python_script.run_command ~stdout_fd:fd
         precheck_script json_params [] <> 0 then
      error (f_"failed server prechecks, see earlier errors");
    let json = JSON_parser.json_parser_tree_parse_file precheck_json in
    debug "precheck output parsed as: %s"
      (JSON.string_of_doc ~fmt:JSON.Indented ["", json]);
    let rhv_storagedomain_uuid =
      Some (JSON_parser.object_get_string "rhv_storagedomain_uuid" json) in
    let rhv_cluster_uuid =
      Some (JSON_parser.object_get_string "rhv_cluster_uuid" json) in
    let rhv_cluster_cpu_architecture =
      Some (JSON_parser.object_get_string "rhv_cluster_cpu_architecture" json) in

    (* If the disk UUIDs were not provided, then generate them.
     * This is simpler than letting RHV generate them and trying
     * to read them back from RHV.
     *)
    let disk_uuids =
      match rhv_disk_uuids with
      | Some uuids ->
         let nr_disks = List.length disks in
         if List.length uuids <> nr_disks then
           error (f_"the number of ‘-oo rhv-disk-uuid’ parameters passed on th
e command line has to match the number of guest disk images (for this guest: %d)") nr_disks;
         uuids
      | None -> List.map (fun _ -> uuidgen ()) disks in

    (* This will accumulate the list of transfer IDs from the transfer
     * script.
     *)
    let transfer_ids = ref [] in

    let rhv_cluster_name =
      match List.assoc "rhv_cluster" json_params with
      | JSON.String s -> s
      | _ -> assert false in

    let json_params =
      ("output_name", JSON.String output_name) :: json_params in

    (* Check that the VM does not exist.  This can't run in #precheck because
     * we need to know the name of the virtual machine.
     *)
    if Python_script.run_command vmcheck_script json_params [] <> 0 then
      error (f_"failed vmchecks, see earlier errors");

    (* Cancel the transfer and delete disks.
     *
     * This ignores errors since the only time we are doing this is on
     * the failure path.
     *)
    let cancel transfer_ids disk_uuids =
      let ids = List.map (fun id -> JSON.String id) transfer_ids in
      let json_params = ("transfer_ids", JSON.List ids) :: json_params in
      let ids = List.map (fun uuid -> JSON.String uuid) disk_uuids in
      let json_params = ("disk_uuids", JSON.List ids) :: json_params in
      ignore (Python_script.run_command cancel_script json_params [])
    in

    (* Set up an at-exit handler to perform some cleanups.
     * - Kill nbdkit PIDs (only before finalization).
     * - Delete the orphan disks (only on conversion failure).
     *)
    let nbdkit_pids = ref [] in
    On_exit.f (
      fun () ->
        (* Kill the nbdkit PIDs. *)
        List.iter (
          fun pid ->
            try kill pid Sys.sigterm
            with exn -> debug "%s" (Printexc.to_string exn)
        ) !nbdkit_pids;
        nbdkit_pids := [];

        (* virt-v2v writes v2vdir/done on success only. *)
        let success = Sys.file_exists (dir // "done") in
        if not success then (
          if disk_uuids <> [] then
            cancel !transfer_ids disk_uuids
        )
    );

    (* Create an nbdkit instance for each disk and set the
     * target URI to point to the NBD socket.
     *)
    List.iter (
      fun ((i, size), uuid) ->
        let socket = sprintf "%s/out%d" dir i in
        On_exit.unlink socket;

        let disk_name = sprintf "%s-%03d" output_name i in
        let json_params =
          ("disk_name", JSON.String disk_name) :: json_params in

        let disk_format =
          match output_format with
          | "raw" as fmt -> fmt
          | "qcow2" as fmt -> fmt
          | _ ->
             error (f_"rhv-upload: -of %s: Only output format ‘raw’ or ‘qcow2’ is supported.  If the input is in a different format then force one of these output formats by adding either ‘-of raw’ or ‘-of qcow2’ on the command line.")
               output_format in
        let json_params =
          ("disk_format", JSON.String disk_format) :: json_params in

        let json_params =
          ("disk_size", JSON.Int size) :: json_params in

        let json_params =
          ("disk_uuid", JSON.String uuid) :: json_params in

        (* Write the JSON parameters to a file. *)
        let json_param_file = dir // sprintf "out.params%d.json" i in
        with_open_out
          json_param_file
          (fun chan -> output_string chan (JSON.string_of_doc json_params));

        (* Start the transfer. *)
        let transfer_json = dir // "v2vtransfer.json" in
        let fd = Unix.openfile transfer_json [O_WRONLY; O_CREAT] 0o600 in
        if Python_script.run_command ~stdout_fd:fd
             transfer_script json_params [] <> 0 then
          error (f_"failed to start transfer, see earlier errors");
        let json = JSON_parser.json_parser_tree_parse_file transfer_json in
        debug "transfer output parsed as: %s"
          (JSON.string_of_doc ~fmt:JSON.Indented ["", json]);
        let destination_url =
          JSON_parser.object_get_string "destination_url" json in
        let transfer_id =
          JSON_parser.object_get_string "transfer_id" json in
        List.push_back transfer_ids transfer_id;
        let is_ovirt_host =
          JSON_parser.object_get_bool "is_ovirt_host" json in

        (* Create the nbdkit instance. *)
        Nbdkit.add_arg cmd "size" (Int64.to_string size);
        Nbdkit.add_arg cmd "url" destination_url;
        Option.may (Nbdkit.add_arg cmd "cafile") rhv_cafile;
        if not rhv_verifypeer then
          Nbdkit.add_arg cmd "insecure" "true";
        if is_ovirt_host then
          Nbdkit.add_arg cmd "is_ovirt_host" "true";
        let _, pid = Nbdkit.run_unix ~socket cmd in
        List.push_front pid nbdkit_pids
    ) (List.combine disks disk_uuids);

    (* Stash some data we will need during finalization. *)
    let disk_sizes = List.map snd disks in
    let t = (disk_sizes : int64 list), disk_uuids, !transfer_ids,
            finalize_script, createvm_script, json_params,
            rhv_storagedomain_uuid, rhv_cluster_uuid,
            rhv_cluster_cpu_architecture, rhv_cluster_name, nbdkit_pids in
    t

  and json_optstring = function
    | Some s -> JSON.String s
    | None -> JSON.Null

  let finalize dir options t source inspect target_meta =
    let output_conn, output_format,
        output_password, output_name, output_storage,
        rhv_cafile, rhv_cluster, rhv_direct,
        rhv_verifypeer, rhv_disk_uuids = options in
    let disk_sizes, disk_uuids, transfer_ids,
        finalize_script, createvm_script, json_params,
        rhv_storagedomain_uuid, rhv_cluster_uuid,
        rhv_cluster_cpu_architecture, rhv_cluster_name,
        nbdkit_pids = t in

    (* Check the cluster CPU arch matches what we derived about the
     * guest during conversion.
     *)
    (match rhv_cluster_cpu_architecture with
     | None -> assert false
     | Some arch ->
        if arch <> target_meta.guestcaps.gcaps_arch then
          error (f_"the cluster ‘%s’ does not support the architecture %s but %s")
            rhv_cluster_name target_meta.guestcaps.gcaps_arch arch
    );

    (* We must kill all our nbdkit instances before finalizing the
     * transfer.  See:
     * https://listman.redhat.com/archives/libguestfs/2022-February/msg00111.html
     *
     * We want to fail here if the kill fails because nbdkit
     * died already, as that would be unexpected.
     *)
    let () =
      let pids = !nbdkit_pids in
      List.iter (fun pid -> kill pid Sys.sigterm) pids;
      List.iter (fun pid -> ignore (waitpid [] pid)) pids;
      nbdkit_pids := [] (* Don't kill them again in the On_exit handler. *) in

    (* Finalize all the transfers. *)
    let json_params =
      let ids = List.map (fun id -> JSON.String id) transfer_ids in
      let json_params = ("transfer_ids", JSON.List ids) :: json_params in
      let ids = List.map (fun uuid -> JSON.String uuid) disk_uuids in
      let json_params = ("disk_uuids", JSON.List ids) :: json_params in
      json_params in
    if Python_script.run_command finalize_script json_params [] <> 0 then
      error (f_"failed to finalize the transfers, see earlier errors");

    (* The storage domain UUID. *)
    let sd_uuid =
      match rhv_storagedomain_uuid with
      | None -> assert false
      | Some uuid -> uuid in

    (* The volume and VM UUIDs are made up. *)
    let vol_uuids = List.map (fun _ -> uuidgen ()) disk_sizes
    and vm_uuid = uuidgen () in

    (* Create the metadata. *)
    let ovf =
      Create_ovf.create_ovf source inspect target_meta disk_sizes
        Sparse output_format output_name
        sd_uuid disk_uuids vol_uuids dir vm_uuid OVirt in
    let ovf = DOM.doc_to_string ovf in

    let json_params =
      match rhv_cluster_uuid with
      | None -> assert false
      | Some uuid -> ("rhv_cluster_uuid", JSON.String uuid) :: json_params in

    let ovf_file = dir // "vm.ovf" in
    with_open_out ovf_file (fun chan -> output_string chan ovf);
    if Python_script.run_command createvm_script json_params [ovf_file] <> 0
    then
      error (f_"failed to create virtual machine, see earlier errors")
end
