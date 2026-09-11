(* MCP dispatch over stdio. Newline-delimited JSON, not LSP framing.

   Both handshakes are answered: 2026-07-28 retired initialize in favour of
   an optional server/discover, but clients on the older revision still send
   initialize, and tool dispatch is identical either way.

   isError is reserved for infrastructure failure. A phrase that fails to
   typecheck is a successful eval whose verdict is negative and comes back as
   an ordinary result; isError means the server failed at its own job. *)

(* The newest revision we know of. It is what server/discover advertises, but
   it is not what we force on a client: tool dispatch is identical across these
   revisions, so an initialize is answered with the version the client asked
   for. Claude Code, for instance, speaks 2025-11-25 and refuses to connect to
   a server that answers with anything else. *)
let protocol_version = "2026-07-28"

let server_info =
  `Assoc [ "name", `String "camlkit"; "version", `String "0.1.0" ]

let capabilities = `Assoc [ "tools", `Assoc [] ]

let result_for version =
  `Assoc [ "protocolVersion", `String version;
           "capabilities", capabilities;
           "serverInfo", server_info ]

let discover_result = result_for protocol_version

(* Agree on what the client asked for when it said; the handshake is the only
   place these revisions differ for a tools-only server. *)
let initialize_result params =
  match Yojson.Safe.Util.member "protocolVersion" params with
  | `String v -> result_for v
  | _ -> discover_result

let tools_list = `Assoc [ "tools", `List Tools.all ]

let text s = `Assoc [ "type", `String "text"; "text", `String s ]

let tool_result ?structured ?(is_error = false) content =
  let base = [ "content", `List content; "isError", `Bool is_error ] in
  `Assoc (match structured with
      | None -> base
      | Some s -> ("structuredContent", s) :: base)

(* [call] performs a tool and is supplied by the server, which owns sessions. *)
let dispatch ~call (request : Jsonrpc.Request.t) =
  let params = match request.params with
    | Some (`Assoc _ as a) -> a
    | _ -> `Assoc [] in
  match request.method_ with
  | "initialize" -> Ok (initialize_result params)
  | "server/discover" -> Ok discover_result
  | "tools/list" -> Ok tools_list
  | "tools/call" -> call params
  | m -> Error (Jsonrpc.Response.Error.make ~code:MethodNotFound
                  ~message:("no such method: " ^ m) ())

let respond oc (packet : Jsonrpc.Packet.t) =
  output_string oc (Yojson.Safe.to_string (Jsonrpc.Packet.yojson_of_t packet));
  output_char oc '\n';
  flush oc
