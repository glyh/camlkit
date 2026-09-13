(* The helpers [@@deriving mcp] expands into. Every derived type [t] gets
   [t_to_json], [t_of_json], [t_schema_in] and [t_schema_out]; a type the
   deriver knows, such as [string] or [list], is answered from here under the
   same names. See docs/wayfinder/tickets/071. *)

type json = Yojson.Safe.t

let ( let* ) = Result.bind

(* A derived type's four values in one, so a tool is declared with [t_mcp]
   rather than four names. *)
type 'a codec = {
  to_json : 'a -> json;
  of_json : json -> ('a, string) result;
  schema_in : json;
  schema_out : json;
}

(* --- encoding ----------------------------------------------------------- *)

let string_to_json s : json = `String s
let int_to_json n : json = `Int n
let bool_to_json b : json = `Bool b
let float_to_json f : json = `Float f
let json_to_json (j : json) = j
let list_to_json f l : json = `List (List.map f l)
let option_to_json f = function None -> `Null | Some x -> f x

(* --- decoding ----------------------------------------------------------- *)

(* Decoding is for input: a client's arguments and merlin's answers. It is
   strict, so a field that is neither an option nor defaulted has to be there,
   which is what the input schema's `required` says. *)

let fail what j =
  Error (Printf.sprintf "expected %s, got %s" what (Yojson.Safe.to_string j))

let string_of_json = function `String s -> Ok s | j -> fail "a string" j
let int_of_json = function `Int n -> Ok n | j -> fail "an integer" j
let bool_of_json = function `Bool b -> Ok b | j -> fail "a boolean" j

let float_of_json = function
  | `Float f -> Ok f
  | `Int n -> Ok (float_of_int n)
  | j -> fail "a number" j

let json_of_json (j : json) = Ok j

let list_of_json f = function
  | `List items ->
    let rec go i acc = function
      | [] -> Ok (List.rev acc)
      | x :: rest ->
        (match f x with
         | Ok v -> go (i + 1) (v :: acc) rest
         | Error e -> Error (Printf.sprintf "[%d]: %s" i e))
    in
    go 0 [] items
  | j -> fail "an array" j

let option_of_json f = function
  | `Null -> Ok None
  | j -> Result.map Option.some (f j)

let fields_of = function `Assoc fields -> Ok fields | j -> fail "an object" j

let within name = Result.map_error (fun e -> name ^ ": " ^ e)

let required name dec fields =
  match List.assoc_opt name fields with
  | Some j -> within name (dec j)
  | None -> Error ("missing field " ^ name)

let optional name dec fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some j -> within name (Result.map Option.some (dec j))

let defaulted name dec default fields =
  match List.assoc_opt name fields with
  | None -> Ok default
  | Some j -> within name (dec j)

let tag_of tag fields =
  match List.assoc_opt tag fields with
  | Some (`String s) -> Ok s
  | Some j -> within tag (fail "a string" j)
  | None -> Error ("missing field " ^ tag)

(* --- schemas ------------------------------------------------------------ *)

let typed t : json = `Assoc [ "type", `String t ]
let string_schema = typed "string"
let int_schema = typed "integer"
let bool_schema = typed "boolean"
let float_schema = typed "number"
let json_schema : json = `Assoc []
let list_schema items : json = `Assoc [ "type", `String "array"; "items", items ]

(* A reference to a type in the same `type ... and ...` group. Its schema is
   still being defined, so it is described by its shape alone.
   ponytail: shallow, which leaves a recursive item's children undescribed;
   $defs and $ref if a client ever needs the depth. *)
let shallow_object = typed "object"
let shallow_string = typed "string"

let describe doc : json -> json = function
  | `Assoc fields -> `Assoc (fields @ [ "description", `String doc ])
  | other -> other

let names l : json = `List (List.map (fun n -> `String n) l)

let obj ~required props : json =
  `Assoc ([ "type", `String "object"; "properties", `Assoc props ]
          @ if required = [] then [] else [ "required", names required ])

(* One constructor of a tagged variant: the tag is a const and always there. *)
let tagged ~tag ~value ~required props =
  obj ~required:(tag :: required)
    ((tag, `Assoc [ "const", `String value ]) :: props)

let one_of branches : json =
  `Assoc [ "type", `String "object"; "oneOf", `List branches ]

let enum values : json = `Assoc [ "type", `String "string"; "enum", names values ]
