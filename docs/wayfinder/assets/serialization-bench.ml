open Bin_prot.Std
(* Response record: small fields + one big opaque string. *)
type status = Ok_ | Error_ | Timeout [@@deriving bin_io]

type resp = {
  session_id : string;
  status : status;
  output : string;                    (* the big one *)
  spans : (int * int) list option;
  warning : string option;
} [@@deriving bin_io]

let mk n =
  let b = Buffer.create n in
  let line = "let rec f x = \"quoted\\n\" ^ g x in val f : int -> string = <fun>\n" in
  while Buffer.length b < n do Buffer.add_string b line done;
  { session_id = "sess-0123456789abcdef";
    status = Ok_;
    output = Buffer.sub b 0 n;
    spans = Some [ (12, 34); (56, 78) ];
    warning = Some "unused variable x" }

(* ---- baseline: naive length-prefixed Buffer copy ---- *)
let base_enc r =
  let b = Buffer.create (String.length r.output + 64) in
  Buffer.add_string b r.session_id; Buffer.add_char b '\000';
  Buffer.add_int32_be b (Int32.of_int (String.length r.output));
  Buffer.add_string b r.output;
  Buffer.contents b
let base_dec (s : string) =
  let i = String.index s '\000' in
  let sid = String.sub s 0 i in
  let len = Int32.to_int (String.get_int32_be s (i + 1)) in
  (sid, String.sub s (i + 5) len)

(* ---- bin_prot ---- *)
let bp_enc r =
  let n = bin_size_resp r in
  let buf = Bin_prot.Common.create_buf n in
  ignore (bin_write_resp buf ~pos:0 r);
  let s = Bytes.create n in
  Bin_prot.Common.blit_buf_bytes buf s ~len:n;
  Bytes.unsafe_to_string s
let bp_dec (s : string) =
  let n = String.length s in
  let buf = Bin_prot.Common.create_buf n in
  Bin_prot.Common.blit_string_buf s buf ~len:n;
  bin_read_resp buf ~pos_ref:(ref 0)

(* ---- msgpck ---- *)
let mp_of r =
  let open Msgpck in
  of_list [ of_string r.session_id; of_int 0; of_bytes r.output;
            of_list (match r.spans with None -> []
                     | Some l -> List.concat_map (fun (a,b) -> [of_int a; of_int b]) l);
            (match r.warning with None -> of_nil | Some w -> of_string w) ]
let mp_enc r = Buffer.contents (Msgpck.StringBuf.to_string (mp_of r))
let mp_dec s = snd (Msgpck.StringBuf.read s)

(* ---- cbor ---- *)
let cb_of r : CBOR.Simple.t =

  `Array [ `Text r.session_id; `Int 0; `Bytes r.output;
           `Array (match r.spans with None -> []
                   | Some l -> List.concat_map (fun (a,b) -> [`Int a; `Int b]) l);
           (match r.warning with None -> `Null | Some w -> `Text w) ]
let cb_enc r = CBOR.Simple.encode (cb_of r)
let cb_dec s = CBOR.Simple.decode s

(* ---- yojson ---- *)
let js_of r : Yojson.Safe.t =
  `Assoc [ "session_id", `String r.session_id; "status", `String "ok";
           "output", `String r.output;
           "spans", (match r.spans with None -> `Null
                     | Some l -> `List (List.map (fun (a,b) -> `List [`Int a; `Int b]) l));
           "warning", (match r.warning with None -> `Null | Some w -> `String w) ]
let js_enc r = Yojson.Safe.to_string (js_of r)
let js_dec s = Yojson.Safe.from_string s

let median l = let a = Array.of_list l in Array.sort compare a; a.(Array.length a / 2)

let time n f x =
  let ts = List.init n (fun _ ->
    let t0 = Unix.gettimeofday () in
    Sys.opaque_identity (ignore (f x));
    (Unix.gettimeofday () -. t0) *. 1e3) in
  median ts

let () =
  Printf.printf "%-10s %-9s %10s %12s %12s\n" "size" "lib" "bytes" "enc_ms" "dec_ms";
  List.iter (fun (label, n) ->
    let r = mk n in
    let iters = if n >= 1_000_000 then 40 else 300 in
    List.iter (fun (name, enc, dec) ->
      let s = enc r in
      (* warmup *)
      for _ = 1 to 5 do ignore (Sys.opaque_identity (enc r)); ignore (Sys.opaque_identity (dec s)) done;
      let e = time iters enc r and d = time iters dec s in
      Printf.printf "%-10s %-9s %10d %12.3f %12.3f\n%!" label name (String.length s) e d)
      [ "baseline", base_enc, (fun s -> ignore (base_dec s));
        "bin_prot", bp_enc, (fun s -> ignore (bp_dec s));
        "msgpck",   mp_enc, (fun s -> ignore (mp_dec s));
        "cbor",     cb_enc, (fun s -> ignore (cb_dec s));
        "yojson",   js_enc, (fun s -> ignore (js_dec s)) ])
    [ "1KB", 1_000; "100KB", 100_000; "1MB", 1_000_000; "10MB", 10_000_000 ]

(* roundtrip self-check *)
let () =
  let r = mk 5000 in
  assert (snd (base_dec (base_enc r)) = r.output);
  assert ((bp_dec (bp_enc r)).output = r.output);
  assert (Msgpck.to_bytes (List.nth (Msgpck.to_list (mp_dec (mp_enc r))) 2) = r.output);
  assert ((match cb_dec (cb_enc r) with `Array l -> (match List.nth l 2 with `Bytes s -> s | _ -> "") | _ -> "") = r.output);
  assert (Yojson.Safe.Util.(js_dec (js_enc r) |> member "output" |> to_string) = r.output);
  prerr_endline "roundtrip ok"
