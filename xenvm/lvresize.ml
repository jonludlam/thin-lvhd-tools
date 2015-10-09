(* LVM compatible bits and pieces *)

open Cmdliner
open Lwt
open Xenvm_common
open Retry

let resize_remotely info vg_name lv_name size =
  let module DM = (val !dm : S.RETRYMAPPER) in
  let dm_name = Mapper.name_of vg_name lv_name in
  DM.ls () >>= fun all ->
  let device_is_active = List.mem dm_name all in

  Client.get_lv ~name:lv_name >>= fun (vg, lv) ->
  if vg.Lvm.Vg.name <> vg_name then failwith "Invalid VG name";
  let local_device = match info with
  | Some info -> info.local_device (* If we've got a default, use that *)
  | None -> failwith "Need to know the local device!" in

  let existing_size = Int64.(mul (mul 512L vg.Lvm.Vg.extent_size) (Lvm.Lv.size_in_extents lv)) in

  begin
    if device_is_active then DM.suspend dm_name
    else return ()
  end
  >>= fun () ->

  Lwt.catch
    (fun () ->
      match size with
      | `Absolute size -> Client.resize lv_name size
      | `IncreaseBy delta -> Client.resize lv_name Int64.(add delta existing_size)
    ) (function
      | Xenvm_interface.Insufficient_free_space(needed, available) ->
        Printf.fprintf Pervasives.stderr "Insufficient free space: %Ld extents needed, but only %Ld available\n%!" needed available;
        (if device_is_active then DM.resume dm_name else Lwt.return ()) >>= fun () -> exit 5
      | e ->
        (if device_is_active then DM.resume dm_name else Lwt.return ()) >>= fun () -> fail e
    )
  >>= fun () ->
  if device_is_active then begin
    Client.get_lv ~name:lv_name >>= fun (vg, lv) ->
    Mapper.read [ local_device ]
    >>= fun devices ->
    let targets = Mapper.to_targets devices vg lv in

    DM.reload dm_name targets
    >>= fun () ->
    DM.resume dm_name
  end else return ()

let resize_locally allocator vg_name lv_name size =
  let dm_name = Mapper.name_of vg_name lv_name in
  let s = Lwt_unix.socket Lwt_unix.PF_UNIX Lwt_unix.SOCK_STREAM 0 in
  Lwt_unix.connect s (Unix.ADDR_UNIX allocator)
  >>= fun () ->
  let oc = Lwt_io.of_fd ~mode:Lwt_io.output s in
  let r = { ResizeRequest.local_dm_name = dm_name; action = size } in
  Lwt_io.write_line oc (Sexplib.Sexp.to_string (ResizeRequest.sexp_of_t r))
  >>= fun () ->
  let ic = Lwt_io.of_fd ~mode:Lwt_io.input ~close:return s in
  Lwt_io.read_line ic
  >>= fun txt ->
  let resp = ResizeResponse.t_of_sexp (Sexplib.Sexp.of_string txt) in
  Lwt_io.close oc
  >>= fun () ->
  match resp with
  | ResizeResponse.Success
  | ResizeResponse.Request_for_no_segments 0L ->
    return ()
  | ResizeResponse.Request_for_no_segments nr ->
    stderr "Request for an illegal number of segments: %Ld" nr
    >>= fun () ->
    exit 2
  | ResizeResponse.Device_mapper_device_does_not_exist dm_name ->
    stderr "Device mapper device does not exist: %s" dm_name
    >>= fun () ->
    exit 1

let lvresize copts live (vg_name,lv_opt) real_size percent_size =
  let lv_name = match lv_opt with | Some l -> l | None -> failwith "Need an LV name" in
  let open Xenvm_common in
  let size = match parse_size real_size percent_size with
  | `IncreaseBy x -> `IncreaseBy x
  | `Absolute x -> `Absolute x
  | `Free _ -> failwith "Resizing to a percentage of free space not supported"
  | `DecreaseBy _ -> failwith "Shrinking volumes not supported"
  | `Extents _ -> failwith "Resizing in terms of extents not supported" in

  let t =
    get_vg_info_t copts vg_name >>= fun info ->
    set_uri copts info;
    match live, info with
    | true, Some { Xenvm_common.local_allocator_path = Some allocator } ->
      resize_locally allocator vg_name lv_name size
    | true, _ ->
      fail (Failure "Live resize requested, but local allocator path unset") 
    | _, _ ->
      resize_remotely info vg_name lv_name size
  in
  Lwt_main.run t

let live_arg =
  let doc = "Resize a live device using the local allocator" in
  Arg.(value & flag & info ["live"] ~doc)

let lvresize_cmd =
  let doc = "Resize a logical volume" in
  let man = [
    `S "DESCRIPTION";
    `P "lvresize will resize an existing logical volume.";
  ] in
  Term.(pure lvresize $ Xenvm_common.copts_t $ live_arg $ Xenvm_common.name_arg $ Xenvm_common.real_size_arg $ Xenvm_common.percent_size_arg),
  Term.info "lvresize" ~sdocs:"COMMON OPTIONS" ~doc ~man

let lvextend_cmd =
  let doc = "Resize a logical volume" in
  let man = [
    `S "DESCRIPTION";
    `P "lvextend will resize an existing logical volume.";
  ] in
  Term.(pure lvresize $ Xenvm_common.copts_t $ live_arg $ Xenvm_common.name_arg $ Xenvm_common.real_size_arg $ Xenvm_common.percent_size_arg),
  Term.info "lvextend" ~sdocs:"COMMON OPTIONS" ~doc ~man
