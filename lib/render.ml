(* A tool result as it is sent: the text, the structure, and whether the server
   failed at its own job. What goes in them is Tool's and Session_result's
   business; see docs/wayfinder/tickets/071. *)

type t = {
  content : string;
  structured : Yojson.Safe.t;
  is_error : bool;
}

(* How a worker ended, as words and as fields: the code of an exit, or the
   signal that killed it, which is what tells `exit 3` from a segfault. *)
let signal_name n =
  List.assoc_opt n
    [ Sys.sigsegv, "SIGSEGV"; Sys.sigkill, "SIGKILL"; Sys.sigabrt, "SIGABRT";
      Sys.sigbus, "SIGBUS"; Sys.sigfpe, "SIGFPE"; Sys.sigterm, "SIGTERM";
      Sys.sigint, "SIGINT"; Sys.sigill, "SIGILL"; Sys.sigpipe, "SIGPIPE" ]
  |> Option.value ~default:(Printf.sprintf "signal %d" n)

let how_it_ended = function
  | Some (Unix.WEXITED n) -> Printf.sprintf "exited with code %d" n
  | Some (Unix.WSIGNALED n) -> "was killed by " ^ signal_name n
  | Some (Unix.WSTOPPED n) -> "was stopped by " ^ signal_name n
  | None -> "died"

(* The code of an exit, or the signal that killed it. *)
let exit_status = function
  | Some (Unix.WEXITED n) -> (Some n, None)
  | Some (Unix.WSIGNALED n) | Some (Unix.WSTOPPED n) -> (None, Some (signal_name n))
  | None -> (None, None)
