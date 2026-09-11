(* Imperative shell for Frame. Everything here is I/O; the codec itself is in
   Frame and knows nothing about channels. *)

exception Truncated

let write oc frame =
  output_string oc (Frame.encode frame);
  flush oc

(* None at a clean EOF; Truncated if a frame was cut mid-way. *)
let read ic =
  let buf = Buffer.create 512 in
  let rec go () =
    match Frame.parse (Buffer.contents buf) with
    | Frame.Complete (frame, _) -> Some frame
    | Frame.Malformed m -> failwith m
    | Frame.Need n ->
      let chunk = Bytes.create n in
      (match really_input ic chunk 0 n with
       | () -> Buffer.add_bytes buf chunk; go ()
       | exception End_of_file ->
         if Buffer.length buf = 0 then None else raise Truncated)
  in
  go ()
