(* virt-v2v
 * Copyright (C) 2009-2019 Red Hat Inc.
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

open Std_utils
open Tools_utils
open Common_gettext.Gettext

open Types
open Parse_ova
open Parse_ovf_from_ova
open Name_from_disk

(* RHBZ#1570407: VMware-generated OVA files found in the wild can
 * contain hrefs referencing snapshots.  The href will be something
 * like: <File href="disk1.vmdk"/> but the actual disk will be a
 * snapshot called something like "disk1.vmdk.000000000".
 *)
let re_snapshot = PCRE.compile "\\.(\\d+)$"

let rec find_file_or_snapshot ova_t href manifest =
  match resolve_href ova_t href with
  | Some f -> f
  | None ->
     (* Find all files in the OVA called [<href>.\d+] *)
     let files = get_file_list ova_t in
     let snapshots =
       List.filter_map (
         function
         | LocalFile filename -> get_snapshot_if_matches href filename
         | TarFile (_, filename) -> get_snapshot_if_matches href filename
       ) files in
     (* Pick highest. *)
     let snapshots = List.sort (fun a b -> compare b a) snapshots in
     match snapshots with
     | [] -> error_missing_href href
     | snapshot::_ ->
        let href = sprintf "%s.%s" href snapshot in
        match resolve_href ova_t href with
        | None -> error_missing_href href
        | Some f -> f

(* If [filename] matches [<href>.\d+] then return [Some snapshot]. *)
and get_snapshot_if_matches href filename =
  if PCRE.matches re_snapshot filename then (
    let snapshot = PCRE.sub 1 in
    if String.is_suffix filename (sprintf "%s.%s" href snapshot) then
      Some snapshot
    else
      None
  )
  else None

and error_missing_href href =
  error (f_"-i ova: OVF references file ‘%s’ which was not found in the OVA archive") href

class input_ova ova = object
  inherit input

  method as_options = "-i ova " ^ ova

  method source ?bandwidth () =
    (* Extract ova file. *)
    let ova_t = parse_ova ova in

    (* Extract ovf file from ova. *)
    let ovf = get_ovf_file ova_t in

    (* Extract the manifest from *.mf files in the ova. *)
    let manifest = get_manifest ova_t in

    (* Verify checksums of files listed in the manifest. *)
    List.iter (
      fun (file_ref, csum) ->
        let filename, r =
          match file_ref with
          | LocalFile filename ->
             filename, Checksums.verify_checksum csum filename
          | TarFile (tar, filename) ->
             filename, Checksums.verify_checksum csum ~tar filename in
        match r with
        | Checksums.Good_checksum -> ()
        | Checksums.Mismatched_checksum (_, actual) ->
           error (f_"-i ova: corrupt OVA: checksum of disk %s does not match manifest (actual = %s, expected = %s)")
                 filename actual (Checksums.string_of_csum_t csum)
        | Checksums.Missing_file ->
           (* RHBZ#1570407: Some OVA files generated by VMware
            * reference non-existent components in the *.mf file.
            * Generate a warning and ignore it.
            *)
           warning (f_"manifest has a checksum for non-existent file %s (ignored)")
                   filename
    ) manifest;

    (* Parse the ovf file. *)
    let name, memory, vcpu, cpu_topology, firmware, disks, removables, nics =
      parse_ovf_from_ova ovf in

    let name =
      match name with
      | None ->
         warning (f_"could not parse ovf:Name from OVF document");
         name_from_disk ova
      | Some name -> name in

    (* Convert the disk hrefs into qemu URIs. *)
    let qemu_uris = List.map (
      fun { href; compressed } ->
        let file_ref = find_file_or_snapshot ova_t href manifest in

        match compressed, file_ref with
        | false, LocalFile filename ->
           filename

        | true, LocalFile filename ->
           (* The spec allows the file to be gzip-compressed, in
            * which case we must uncompress it into a temporary.
            *)
           let temp_dir = (open_guestfs ())#get_cachedir () in
           let new_filename = Filename.temp_file ~temp_dir "ova" ".vmdk" in
           unlink_on_exit new_filename;
           let cmd =
             sprintf "zcat %s > %s" (quote filename) (quote new_filename) in
           if shell_command cmd <> 0 then
             error (f_"error uncompressing %s, see earlier error messages")
                   filename;
           new_filename

        | false, TarFile (tar, filename) ->
           (* This is the tar optimization. *)
           let offset, size =
             try Parse_ova.get_tar_offet_and_size tar filename
             with
             | Not_found ->
                error (f_"file ‘%s’ not found in the ova") filename
             | Failure msg -> error (f_"%s") msg in
           (* QEMU requires size aligned to 512 bytes. This is safe because
            * tar also works with 512 byte blocks.
            *)
           let size = roundup64 size 512L in

           (* Workaround for libvirt bug RHBZ#1431652. *)
           let tar_path = absolute_path tar in

           let doc = [
               "file", JSON.Dict [
                           "driver", JSON.String "raw";
                           "offset", JSON.Int offset;
                           "size", JSON.Int size;
                           "file", JSON.Dict [
                                       "driver", JSON.String "file";
                                       "filename", JSON.String tar_path]
                         ]
             ] in
           let uri =
             sprintf "json:%s" (JSON.string_of_doc ~fmt:JSON.Compact doc) in
           uri

        | true, TarFile _ ->
           (* This should not happen since {!Parse_ova} knows that
            * qemu cannot handle compressed files here.
            *)
           assert false
      ) disks in

    (* Get a final list of source disks. *)
    let disks =
      List.map (fun ({ source_disk }, qemu_uri) ->
          { source_disk with s_qemu_uri = qemu_uri })
               (List.combine disks qemu_uris) in

    let source = {
      s_hypervisor = VMware;
      s_name = name;
      s_orig_name = name;
      s_genid = None; (* XXX *)
      s_memory = memory;
      s_vcpu = vcpu;
      s_cpu_vendor = None;
      s_cpu_model = None;
      s_cpu_topology = cpu_topology;
      s_features = []; (* XXX *)
      s_firmware = firmware;
      s_display = None; (* XXX *)
      s_video = None;
      s_sound = None;
      s_removables = removables;
      s_nics = nics;
    } in

    source, disks
end

let input_ova = new input_ova
let () = Modules_list.register_input_module "ova"
