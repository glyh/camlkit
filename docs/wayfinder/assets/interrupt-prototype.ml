let say f = Printf.ksprintf (fun s -> print_string (s ^ "\n"); flush stdout) f
let init () = Sys.interactive := false; Clflags.real_paths := false;
              Toploop.initialize_toplevel_env ()
let parse src = match !UTop.parse_use_file src false with
  | UTop.Value ps -> ps | UTop.Error (_, m) -> failwith m

(* Our handler records the interrupt, then raises as a terminal would. *)
let interrupted = ref false
let arm () =
  ignore (Sys.signal Sys.sigint
            (Sys.Signal_handle (fun _ -> interrupted := true; raise Sys.Break)))

let run label src =
  interrupted := false;
  let ok = try List.for_all (fun p ->
      Toploop.execute_phrase true Format.std_formatter p) (parse src)
    with Sys.Break -> say "    (Sys.Break escaped execute_phrase)"; false
       | exn -> say "    (raised: %s)" (String.concat " "
           (String.split_on_char '\n' (UTop.get_message Errors.report_error exn))); false in
  say "  %-18s ok=%b interrupted=%b" label ok !interrupted

let fire_in secs =
  Sys.set_signal Sys.sigalrm
    (Sys.Signal_handle (fun _ -> Unix.kill (Unix.getpid ()) Sys.sigint));
  ignore (Unix.alarm secs)

let () =
  init (); arm ();
  run "bind" "let keep = 99;;";
  say "-- interrupt a tight loop --";
  fire_in 1; run "spin" "let rec spin n = spin (n + 1) in spin 0;;";
  say "-- state after interrupt --";
  run "read back" "keep;;";
  run "new binding" "let after = keep + 1;;";
  say "-- a genuine type error, for contrast --";
  run "type error" "1 + true;;";
  say "-- a phrase that really swallows Sys.Break --";
  fire_in 1;
  run "swallowing" "let rec s n = (try s (n+1) with Sys.Break -> s (n+1)) in s 0;;";
  say "   reached the end"
