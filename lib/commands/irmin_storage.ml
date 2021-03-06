(*
 * Copyright (c) 2013-2014 Gregory Tsipenyuk <gregtsip@cam.ac.uk>
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
open Storage
open Irmin_core
open Storage_meta
open Server_config

type ('a) _storage = {user:string;mailbox:'a;config:imapConfig}

module GitStorageMake(GM:GitMailboxIntf) : Storage_intf 
  with type t = (GM.t) _storage =
struct
  type t = (GM.t) _storage

  (* user *)
  let create config user mailbox keys =
    GM.create config user mailbox keys >>= fun mailbox ->
    return {user;mailbox;config}

  let exists t = 
    GM.exists t.mailbox

  (* status *)
  let status t =
    GM.read_mailbox_metadata t.mailbox

  (* select mailbox *)
  let select t =
    status t 

  (* examine mailbox *)
  let examine t =
    status t 

  (* create mailbox *)
  let create_mailbox t =
    GM.create_mailbox t.mailbox

  (* delete mailbox *)
  let delete t = 
    GM.delete_mailbox t.mailbox

  (* rename mailbox1 mailbox2 *)
  let rename t mailbox2 =
    GM.move_mailbox t.mailbox mailbox2

  (* subscribe mailbox.
   * subscribe and unsubscribe should be in a separate module TBD 
   *)
  let subscribe t =
    GM.subscribe t.mailbox

  (* unsubscribe mailbox *)
  let unsubscribe t =
    GM.unsubscribe t.mailbox

  (* list 
   * returns list of files/folders with list of flags 
   *)
  let list t ~subscribed ?(access=(fun _ -> true)) ~init ~f =
    GM.list t.mailbox ~subscribed ~access ~init ~f

  (* append message(s) to selected mailbox *)
  let append t message message_metadata =
    GM.append_message t.mailbox message message_metadata

  (* delete a message *)
  let delete_message t position = 
    GM.delete_message t.mailbox position

  (* fetch messages from selected mailbox *)
  let fetch t position =
    GM.read_message t.mailbox position

  (* fetch messages from selected mailbox *)
  let fetch_message_metadata t position =
    GM.read_message_metadata t.mailbox position

  (* store flags to selected mailbox *)
  let store t position message_metadata =
    GM.update_message_metadata t.mailbox position message_metadata >>= fun _ ->
    return ()

  (* store mailbox metadata *)
  let store_mailbox_metadata t mailbox_metadata =
    GM.update_mailbox_metadata t.mailbox mailbox_metadata

  (* copy messages from selected mailbox *)
  let copy t pos t2 message_metadata =
    GM.copy_mailbox t.mailbox pos t2.mailbox message_metadata

  (* commit all updates to the mailbox *)
  let commit t =
    GM.commit t.mailbox

  let uid_to_seq t uid =
    GM.uid_to_seq t.mailbox uid

  let create_account t =
    GM.create_account t.mailbox

  let delete_account t =
    GM.delete_account t.mailbox
end

module IrminStorage = GitStorageMake(GitMailbox)
module GitWorkdirStorage = GitStorageMake(GitWorkdirMailbox)
