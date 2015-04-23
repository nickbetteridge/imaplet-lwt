(*
 * Copyright (c) 2013-2015 Gregory Tsipenyuk <gregtsip@cam.ac.uk>
 * 
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open Lwt
open Imaplet
open Commands
open Server_config
open Irmin_core
open Irmin_storage

exception InvalidCommand
exception SystemFailed
exception AccountExists

let rec args i user force =
  if i >= Array.length Sys.argv then
    user,force
  else
    match Sys.argv.(i) with 
    | "-u" -> args (i+2) (Some Sys.argv.(i+1)) force
    | "-f" -> args (i+1) user true
    | _ -> raise InvalidCommand

let usage () =
  Printf.printf "usage: imaplet_create_account -u [user:pswd] [-f]\n%!"

let commands f =
  try 
    let (user,force) = args 1 None false in
    if user = None || 
      Regex.match_regex ~regx:("^\\([^:]+\\):\\([^:]+\\)$")
      (Utils.option_value_exn user) = false then
      usage ()
    else
      try 
        f (Str.matched_group 1 (Utils.option_value_exn user)) 
          (Str.matched_group 2 (Utils.option_value_exn user)) force
      with ex -> Printf.printf "%s\n%!" (Printexc.to_string ex)
  with _ -> usage ()

let system cmd =
  Lwt_unix.system cmd >>= function
  | WEXITED i -> return (if i = 0 then () else raise SystemFailed) 
  | _ -> raise SystemFailed

let dir f =
  Utils.exists f Unix.S_DIR

let file f =
  Utils.exists f Unix.S_REG

let file_cmd f cmd =
  file f >>= fun res ->
  if res then 
    return ()
  else
    cmd ()

let dir_cmd f cmd =
  dir f >>= fun res ->
  if res then 
    return ()
  else
    cmd ()

(*
imaplet:{PLAIN}imaplet:501:::/Users/imaplet
*)
let set_users user pswd =
  let file = srv_config.users_path in
  Utils.lines_of_file file ~init:false ~f:(fun line acc ->
    if Regex.match_regex ~case:false ~regx:("^" ^ user ^ ":") line then
      return true
    else
      return acc
  ) >>= fun exists ->
  if exists then
    raise AccountExists
  else (
    Lwt_io.with_file ~flags:[O_WRONLY;O_APPEND] ~mode:Lwt_io.output file (fun oc ->
      Lwt_io.write_line oc (Printf.sprintf "%s:{SHA256}%s::::%s" user
      (Imap_crypto.get_hash ~hash:`Sha256 pswd) 
      (Regex.replace ~regx:"%user%" ~tmpl:user srv_config.irmin_path))
    ) >>
    return ()
  )

let () =
  commands (fun user pswd force ->
    Lwt_main.run (
      catch (fun () ->
        set_users user pswd >>= fun () ->
        let cert_path = Regex.replace ~regx:"%user%" ~tmpl:user srv_config.user_cert_path in
        let irmin_path = Regex.replace ~regx:"%user%" ~tmpl:user srv_config.irmin_path in
        let priv_path = Filename.concat cert_path srv_config.key_name in
        let pem_path = Filename.concat cert_path srv_config.pem_name in
        system ("mkdir -p " ^ irmin_path) >>= fun () ->
        (if force then
          system ("rm -rf " ^ (Filename.concat irmin_path ".git"))
        else
          return ()) >>= fun () ->
        system ("mkdir -p " ^ cert_path) >>= fun () ->
        file_cmd priv_path 
          (fun () -> system ("openssl genrsa -out " ^ priv_path ^ " 1024")) >>
        file_cmd pem_path
          (fun () -> system ("openssl req -x509 -key " ^ priv_path ^ " -new -batch -out " ^ pem_path)) >>
        dir_cmd (Filename.concat irmin_path ".git") 
          (fun () -> 
            system ("git init " ^ irmin_path) >>= fun () ->
            let ac = UserAccount.create srv_config user in
            UserAccount.create_account ac >>= fun _ ->
            Ssl_.get_user_keys ~user srv_config >>= fun keys ->
            let create_mailbox mailbox =
              IrminStorage.create srv_config user mailbox keys >>= fun ist ->
              IrminStorage.create_mailbox ist >>
              IrminStorage.subscribe ist >>
              IrminStorage.commit ist
            in
            create_mailbox "INBOX" >>
            create_mailbox "Drafts" >>
            create_mailbox "Deleted Messages" >>
            create_mailbox "Sent Messages"
          ) >>= fun () ->
          Printf.printf "success\n%!";
          return ()
      ) (function
        | SystemFailed -> Printf.printf "failed\n%!"; return ()
        | AccountExists -> Printf.printf "failed\n%!"; return ()
        | _ -> Printf.printf "failed\n%!"; return ())
    )
  )
