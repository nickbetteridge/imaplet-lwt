(*
 * test irmin git/network vs file/network io
 * - create a thousand unique files (compressed to be comparable with irmin)
 * - dump the same files into irmin(git)
 * - fork a tcp client (**)
 * - launch two parallel threads
 * - create a stream
 * - in first thread 
 *  . read from a file/irmin
 *  . add to the stream
 * - in second thread
 *  . read from the stream
 *  . write to the client
 *  (**) repeat several time for file/irmin
 *)
open Lwt
open Irmin_unix

exception InvalidCommand of string

module Store = Irmin.Basic (Irmin_git.FS) (Irmin.Contents.String)

type config =
  {serial:bool;init:bool;compress:bool;yield:bool;block:bool;server:bool;content:string;addr:string;port:int;number:int}

let create_content size = 
  Random.init max_int;
  String.init size (fun i -> 
    let r = (mod) (Random.int 1_000_000) 127 in
    char_of_int (if r >= 0 && r < 32 then r + 32 else r)
  ) 

let usage () =
  Printf.printf "usage: irvsfsio -i (create storage) -c \
  (compress files) -s (file size) -y (yield reading thread) \
  -b (blocking file read) -srl (serial read/write) \
  -srv (server only) -a [server address] -p [server port] -n [repeat]\n"

(* command line *)
let rec args i _init _compr _size _yield _block _server _addr _port _serial
_number =
  if i >= Array.length Sys.argv then
    _init,_compr,_size,_yield,_block,_server,_addr,_port,_serial,_number
  else
    match Sys.argv.(i) with 
    | "-i" -> args (i+1) true _compr _size _yield _block _server _addr _port
      _serial _number
    | "-c" -> args (i+1) _init true _size _yield _block _server _addr _port 
      _serial _number
    | "-s" -> args (i+2) _init _compr (int_of_string Sys.argv.(i+1)) _yield
      _block _server _addr _port _serial _number
    | "-y" -> args (i+1) _init _compr _size true _block _server _addr _port 
      _serial _number
    | "-b" -> args (i+1) _init _compr _size _yield true _server _addr _port
      _serial _number
    | "-srv" -> args (i+1) _init _compr _size _yield _block true _addr _port 
      _serial _number
    | "-a" -> args (i+2) _init _compr _size _yield _block _server Sys.argv.(i+1)
      _port  _serial _number
    | "-p" -> args (i+2) _init _compr _size _yield _block _server _addr 
      (int_of_string Sys.argv.(i+1)) _serial _number
    | "-srl" -> args (i+1) _init _compr _size _yield _block _server _addr _port 
      true _number
    | "-n" -> args (i+2) _init _compr _size _yield _block _server _addr _port 
      _serial (int_of_string Sys.argv.(i+1))
    | "-h" -> usage (); Pervasives.exit 1
    | s -> raise (InvalidCommand s)

let commands f =
  try
    let init,compress,size,yield,block,server,addr,port,serial,number = 
      args 1 false false 100_000 false false false "0.0.0.0" 20001 false 5 in
    f {init;compress;content=create_content
    size;yield;block;server;addr;port;serial;number}
  with InvalidCommand x -> usage (); raise (InvalidCommand x)
(* done command line *)

(* compression *)
let refill input =
  let n = String.length input in
  let toread = ref n in
  fun buf ->
    let m = min !toread (String.length buf) in
    String.blit input (n - !toread) buf 0 m;
    toread := !toread - m;
    m

let flush output buf len =
  Buffer.add_substring output buf 0 len

let flush output buf len =
  Buffer.add_substring output buf 0 len

let do_compress ?(header=false) input =
  let output = Buffer.create (String.length input) in
  Zlib.compress ~level:6 ~header (refill input) (flush output);
  Buffer.contents output

let do_uncompress ?(header=false) input =
  let output = Buffer.create (String.length input) in
  Zlib.uncompress ~header (refill input) (flush output);
  Buffer.contents output
(* done compression *)

let unique_content buff i =
  let id = Printf.sprintf "%07d" i in
  String.blit id 0 buff 0 7;
  buff

let fold_i n f init =
  let rec _fold i acc =
    if i > n then
      return acc
    else (
      f i acc >>= fun acc ->
      _fold (i + 1) acc
    )
  in
  _fold 1 init

let root = "./tmp_ir_fs"
let irmin_root = Filename.concat root "irmin"
let files_root = Filename.concat root "files"

let init () =
  Lwt_unix.system (Printf.sprintf "rm -rf %s" root) >>= fun _ ->
  Lwt_unix.mkdir root 0o777>>= fun () ->
  Lwt_unix.mkdir files_root 0o777>>= fun () ->
  Lwt_unix.mkdir irmin_root 0o777

let create_files config =
  Printf.printf "creating files\n%!";
  fold_i 1_000 (fun i acc ->
    Printf.printf "file %d\r%!" i;
    let file = Printf.sprintf "./tmp_ir_fs/files/%d" i in
    Lwt_io.with_file ~flags:[Unix.O_WRONLY;Unix.O_CREAT;Unix.O_NONBLOCK] ~mode:Lwt_io.Output file (fun w ->
      let content = unique_content config.content i in
      Lwt_io.write w (if config.compress then do_compress ~header:true content else content))
  ) ()

let task msg =
  let date = Int64.of_float (Unix.gettimeofday ()) in
  let owner = "imaplet <imaplet@openmirage.org>" in
  Irmin.Task.create ~date ~owner msg

let create_store () =
  let _config = Irmin_git.config ~root:"./tmp_ir_fs/irmin" ~bare:true ~level:0 () in
  Store.create _config task

let create_irmin config =
  Printf.printf "creating irmin\n%!";
  create_store () >>= fun store ->
  fold_i 1_000 (fun i acc ->
    Printf.printf "irmin %d\r%!" i;
    Store.update (store (Printf.sprintf "updating %d" i)) 
      ["root";string_of_int i] (unique_content config.content i)
  ) ()

let inet_addr addr port = (Unix.ADDR_INET (Unix.inet_addr_of_string addr,port))

let read_response r =
  let rec _read () =
    Lwt_io.read r ~count:(2048*5) >>= fun buff ->
    if buff = "" then (
      return ()
    ) else (
      _read ()
    )
  in
  _read ()

let command config cmd =
  let addr = inet_addr config.addr config.port in
  Lwt_io.with_connection addr (fun (r,w) ->
    Printf.printf "connected to the server, requesting %s\n%!" cmd;
    Lwt_io.write_line w cmd >>= fun () ->
    read_response r
  )

let crt_cmd l cmd num = 
  let rec crt i l =
    if i > num then
      l
    else
      crt (i+1) (cmd :: l)
  in
  crt 1 l

let client config =
  Printf.printf "started client\n%!";
  let cmds = crt_cmd [] "file" config.number in
  let cmds = crt_cmd cmds "irmin" config.number in
  let cmds = List.rev ("quit" :: cmds) in
  Lwt_list.iter_s (command config) cmds

let read_file_lwt file =
  Lwt_io.with_file ~flags:[Unix.O_NONBLOCK] ~mode:Lwt_io.Input file (fun ic ->
    Lwt_io.read ic
  )

let read_file file =
  let st = Unix.stat file in
  let fd = Unix.openfile file [Unix.O_RDONLY] 0o666 in
  let ic = Unix.in_channel_of_descr fd in
  Pervasives.set_binary_mode_in ic false;
  let buff = Pervasives.really_input_string ic st.Unix.st_size in
  Unix.close fd;
  buff

let process_file config id =
  let file = Filename.concat files_root id in
  begin
    if config.block then
      return (read_file file)
    else
      read_file_lwt file
  end >>= fun buff ->
  return (if config.compress then do_uncompress ~header:true buff else buff)

let process_irmin store config id =
  Store.read_exn (store (Printf.sprintf "reading %s" id)) ["root"; id]

let writet = ref 0.
let readt = ref 0.

let write_to_client ts strm w =
  let rec _write i =
    Lwt_stream.get strm >>= function
    | Some buff -> 
      Printf.printf "writing %d\r%!" i;
      let t = Unix.gettimeofday () in
      if i = 1 then
        Printf.printf "### first write delay %.04f\n%!" (t -. ts);
      Lwt_io.write w buff >>= fun () -> 
      writet := !writet +. (Unix.gettimeofday () -. t);
      _write (i+1)
    | None -> return ()
  in
  _write 1

let process config msg w store_reader =
  readt := 0.;
  writet := 0.;
  Printf.printf "processing %s\n%!" msg;
  let (strm,push_strm) = Lwt_stream.create () in
  let t = Unix.gettimeofday () in
  let (f,tm) =
  if config.serial then (
    Lwt_list.iter_s,(fun() -> Unix.gettimeofday())
  ) else (
    Lwt_list.iter_p,(fun() -> t)
  )
  in
  f (fun f -> f()) [
  (fun() ->
  fold_i 1_000 (fun i acc ->
    Printf.printf "reading %d\r%!" i;
    let t = Unix.gettimeofday () in
    store_reader config (string_of_int i) >>= fun buff ->
    readt := !readt +. (Unix.gettimeofday () -. t);
    push_strm (Some buff);
    (if config.yield then Lwt_unix.yield () else return ()) >>= fun () ->
    return acc
  ) () >>= fun () -> push_strm None; return ()
  )
  ;
  (fun() ->
  write_to_client (tm()) strm w
  )
  ] >>= fun () ->
  let total = Unix.gettimeofday () -. t in
  Printf.printf "%s total read %.04f, write %.04f, overall %.04f\n" msg !readt !writet total;
  return ()

let () =
commands (fun config ->
  Lwt_main.run (
    begin
    if config.init then (
      init () >>= fun () ->
      create_files config >>= fun () ->
      create_irmin config 
    ) else
      return ()
    end >>= fun () ->
    if config.server = false && Lwt_unix.fork () = 0 then (
      Lwt_unix.sleep 1. >>= fun () ->
      client config
    ) else (
      let mutex = Lwt_mutex.create () in
      Lwt_mutex.lock mutex >>= fun () ->
      let addr = inet_addr config.addr config.port in
      let server = Lwt_io.establish_server ~backlog:10 addr (fun (r,w) ->
        let loop () =
          Lwt_io.read_line_opt r >>= function
          | Some cmd ->
            Printf.printf "server processing command %s\n%!" cmd;
            begin
              match cmd with
              | "file" -> 
                process config "file" w process_file >>= fun () ->
                Lwt_io.close r >>= fun () -> Lwt_io.close w
              | "irmin" -> 
                create_store () >>= fun store ->
                process config "irmin" w (process_irmin store) >>= fun () ->
                Lwt_io.close r >>= fun () -> Lwt_io.close w
              | _ -> Lwt_io.close w >>= fun () -> Lwt_mutex.unlock mutex; return ()
            end
          | None -> Lwt_io.close w >>= fun () -> Lwt_mutex.unlock mutex; return ()
        in
        async(fun () -> loop ());
        Printf.printf "done iteration\n";
      ) in
      Printf.printf "established server\n%!";
      Lwt_mutex.lock mutex >>= fun () ->
      Lwt_io.shutdown_server server;
      return ()
    )
  )
)
