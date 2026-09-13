(* A tool declared from its types: its argument type gives the input schema and
   decodes the call, its result type gives the output schema and encodes the
   answer, so neither schema can drift from what the tool does. Modelled on the
   C# SDK deriving a tool from one method. See docs/wayfinder/tickets/071. *)

(* The server failing at its own job, as opposed to a negative answer, which is
   a result. Every tool can answer this, so it is declared here once. *)
type failure =
  | Server_error of {
      message : string;
      exit_code : int option;
      (** A worker that exited, with the code it exited with. *)
      signal : string option;
      (** A worker killed by a signal, such as SIGSEGV. *)
    } [@name "error"]
[@@deriving mcp ~tag:"status"]

let failure ?exit_code ?signal message = Server_error { message; exit_code; signal }

(* A failure outside any tool's call, such as a call that raised. *)
let failure_rendering message =
  { Render.content = Yojson.Safe.to_string (failure_to_json (failure message));
    structured = failure_to_json (failure message); is_error = true }

(* Behaviour hints. Each defaults to MCP's own default, which is the worst
   case, and only a hint that differs from its default is sent. *)
type hints = {
  read_only : bool;
  destructive : bool;
  idempotent : bool;
  open_world : bool;
}

type t = {
  name : string;
  declaration : Yojson.Safe.t;
  (* Untyped only at this edge: the arguments as they arrived, and a reply
     that takes the rendering. *)
  call : id:Jsonrpc.Id.t -> Yojson.Safe.t -> reply:(Render.t -> unit) -> unit;
}

let annotations h =
  let hint key value default =
    if value = default then [] else [ key, `Bool value ] in
  hint "readOnlyHint" h.read_only false
  @ (if h.read_only then [] else hint "destructiveHint" h.destructive true)
  @ hint "idempotentHint" h.idempotent false
  @ hint "openWorldHint" h.open_world true

(* The structure, and the same structure serialized as the text: the spec's
   SHOULD, and nothing written beside it to drift. *)
let render ~is_error structured =
  { Render.content = Yojson.Safe.to_string structured; structured; is_error }

let rendered (codec : _ Mcp_derive.codec) = function
  | Ok r -> render ~is_error:false (codec.to_json r)
  | Error f -> render ~is_error:true (failure_to_json f)

(* The one constructor of [failure], rather than a oneOf of one. *)
let failure_branch =
  match Yojson.Safe.Util.member "oneOf" failure_schema_out with
  | `List [ b ] -> b
  | _ -> failure_schema_out

let declare ~name ~doc ~hints (args : _ Mcp_derive.codec) (result : _ Mcp_derive.codec) =
  let description =
    if name = "help" then doc else doc ^ " Manual: help " ^ name ^ "." in
  (* anyOf rather than oneOf: a record result whose fields are all optional
     would also match a failure, and oneOf fails on two matches. *)
  let output =
    `Assoc [ "type", `String "object";
             "anyOf", `List [ result.schema_out; failure_branch ] ] in
  `Assoc ([ "name", `String name;
            "description", `String description;
            "inputSchema", args.schema_in;
            "outputSchema", output ]
          @ match annotations hints with
          | [] -> []
          | a -> [ "annotations", `Assoc a ])

let deferred ~name ~doc ?(read_only = false) ?(destructive = true)
    ?(idempotent = false) ?(open_world = true) args result handler =
  let hints = { read_only; destructive; idempotent; open_world } in
  { name;
    declaration = declare ~name ~doc ~hints args result;
    call = (fun ~id json ~reply ->
        let reply r = reply (rendered result r) in
        match args.Mcp_derive.of_json json with
        | Error why -> reply (Error (failure ("invalid arguments: " ^ why)))
        | Ok a -> handler a ~id ~reply) }

let make ~name ~doc ?read_only ?destructive ?idempotent ?open_world args result
    handler =
  deferred ~name ~doc ?read_only ?destructive ?idempotent ?open_world args result
    (fun a ~id:_ ~reply -> reply (handler a))
