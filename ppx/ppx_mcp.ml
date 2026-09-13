(* [@@deriving mcp] on a type [t] defines

     t_to_json : t -> Yojson.Safe.t
     t_of_json : Yojson.Safe.t -> (t, string) result
     t_schema_in : Yojson.Safe.t      (what a client may send)
     t_schema_out : Yojson.Safe.t     (what we send)
     t_mcp : t Mcp_derive.codec        (the four together)

   from one definition, so a tool's schema and what the tool does with its
   JSON cannot disagree. The rules, decided in docs/wayfinder/tickets/071:

   - A record is an object. Its field is named as written, a trailing _ dropped
     so a keyword can be one (end_ is "end"); [@name "x"] overrides. A doc
     comment on the field is its description.
   - Empty is absent when encoding: None, [], "" and false are left out unless
     the field says [@keep_empty]. A number is always sent. The out schema
     requires exactly the fields that are never left out.
   - Decoding is strict. A field that is not an option and has no
     [@default e] must be present, and the in schema requires exactly those.
   - A variant of constant constructors is a string enum. Any other variant
     needs ~tag:"field": each constructor is an object whose tag holds its
     name, and the schema is a oneOf of them. Constructors are snake_case
     (Not_an_eval is "not_an_eval"); [@name "x"] overrides.
   - Known types: string, int, bool, float, list, option and Yojson.Safe.t.
     Any other type constructor [M.u] is assumed to derive mcp too, and is
     called as [M.u_to_json] and so on. *)

open Ppxlib
module B = Ast_builder.Default

let rt ~loc name = B.evar ~loc ("Mcp_derive." ^ name)

let name_ld =
  Attribute.declare "mcp.name" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload (estring __)) Fun.id

let name_cd =
  Attribute.declare "mcp.name" Attribute.Context.constructor_declaration
    Ast_pattern.(single_expr_payload (estring __)) Fun.id

let keep_empty =
  Attribute.declare "mcp.keep_empty" Attribute.Context.label_declaration
    Ast_pattern.(pstr nil) ()

let default =
  Attribute.declare "mcp.default" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload __) Fun.id

let doc attributes =
  List.find_map
    (fun a ->
       if a.attr_name.txt <> "ocaml.doc" then None
       else
         Ast_pattern.parse
           Ast_pattern.(single_expr_payload (estring __))
           a.attr_loc ~on_error:(fun () -> None) a.attr_payload
           (fun s -> Some (String.trim s)))
    attributes

let snake s =
  let b = Buffer.create (String.length s + 4) in
  String.iteri
    (fun i c ->
       if c >= 'A' && c <= 'Z' then begin
         if i > 0 && s.[i - 1] <> '_' then Buffer.add_char b '_';
         Buffer.add_char b (Char.lowercase_ascii c)
       end
       else Buffer.add_char b c)
    s;
  Buffer.contents b

let key_of_label s =
  let n = String.length s in
  if n > 1 && s.[n - 1] = '_' then String.sub s 0 (n - 1) else s

(* --- types -------------------------------------------------------------- *)

(* The other declarations of the same `type ... and ...` group, and whether
   each is an enum, which is all a reference to one needs for its schema. *)
type ctx = { group : (string * bool) list }

let with_last lid f =
  match lid with
  | Lident n -> Lident (f n)
  | Ldot (m, n) -> Ldot (m, f n)
  | Lapply _ -> lid

let unsupported ~loc =
  Location.raise_errorf ~loc
    "deriving mcp: only string, int, bool, float, list, option, \
     Yojson.Safe.t and named types are supported"

(* The function converting a value of [ty]: suffix is to_json or of_json. *)
let rec conv ~suffix ty =
  let loc = ty.ptyp_loc in
  match ty.ptyp_desc with
  | Ptyp_constr ({ txt = Lident ("string" | "int" | "bool" | "float" as n); _ }, []) ->
    rt ~loc (n ^ "_" ^ suffix)
  | Ptyp_constr ({ txt = Lident ("list" | "option" as n); _ }, [ a ]) ->
    [%expr [%e rt ~loc (n ^ "_" ^ suffix)] [%e conv ~suffix a]]
  | Ptyp_constr ({ txt = Ldot (Ldot (Lident "Yojson", "Safe"), "t"); _ }, []) ->
    rt ~loc ("json_" ^ suffix)
  | Ptyp_constr ({ txt; _ }, []) ->
    B.pexp_ident ~loc { loc; txt = with_last txt (fun n -> n ^ "_" ^ suffix) }
  | _ -> unsupported ~loc

let rec schema ~ctx ~mode ty =
  let loc = ty.ptyp_loc in
  match ty.ptyp_desc with
  | Ptyp_constr ({ txt = Lident ("string" | "int" | "bool" | "float" as n); _ }, []) ->
    rt ~loc (n ^ "_schema")
  | Ptyp_constr ({ txt = Lident "list"; _ }, [ a ]) ->
    [%expr Mcp_derive.list_schema [%e schema ~ctx ~mode a]]
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ a ]) -> schema ~ctx ~mode a
  | Ptyp_constr ({ txt = Ldot (Ldot (Lident "Yojson", "Safe"), "t"); _ }, []) ->
    rt ~loc "json_schema"
  | Ptyp_constr ({ txt = Lident n; _ }, []) when List.mem_assoc n ctx.group ->
    rt ~loc (if List.assoc n ctx.group then "shallow_string" else "shallow_object")
  | Ptyp_constr ({ txt; _ }, []) ->
    B.pexp_ident ~loc { loc; txt = with_last txt (fun n -> n ^ "_schema_" ^ mode) }
  | _ -> unsupported ~loc

(* --- records ------------------------------------------------------------ *)

type field = {
  label : string;
  key : string;
  ty : core_type;
  keep : bool;
  dflt : expression option;
  fdoc : string option;
  floc : location;
}

let field_of (ld : label_declaration) =
  { label = ld.pld_name.txt;
    key = Option.value (Attribute.get name_ld ld) ~default:(key_of_label ld.pld_name.txt);
    ty = ld.pld_type;
    keep = Attribute.get keep_empty ld <> None;
    dflt = Attribute.get default ld;
    fdoc = doc ld.pld_attributes;
    floc = ld.pld_loc }

let kind ty =
  match ty.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ a ]) -> `Option a
  | Ptyp_constr ({ txt = Lident "list"; _ }, [ _ ]) -> `List
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> `String
  | Ptyp_constr ({ txt = Lident "bool"; _ }, []) -> `Bool
  | _ -> `Other

let var f = "mcp__" ^ f.label

(* A list of (key, json) for the fields, which are bound to [var f]. *)
let encode_fields ~loc fields =
  let parts =
    List.map
      (fun f ->
         let loc = f.floc in
         let v = B.evar ~loc (var f) and key = B.estring ~loc f.key in
         match kind f.ty, f.keep with
         | `Option _, true ->
           Location.raise_errorf ~loc "deriving mcp: [@keep_empty] on an option"
         | `Option a, false ->
           [%expr match [%e v] with
             | None -> []
             | Some mcp__x -> [ ([%e key], [%e conv ~suffix:"to_json" a] mcp__x) ]]
         | ((`List | `String | `Bool) as k), false ->
           let empty = match k with
             | `List -> [%expr fun l -> l = []]
             | `String -> [%expr fun s -> s = ""]
             | `Bool -> [%expr not] in
           [%expr if [%e empty] [%e v] then []
             else [ ([%e key], [%e conv ~suffix:"to_json" f.ty] [%e v]) ]]
         | _ -> [%expr [ ([%e key], [%e conv ~suffix:"to_json" f.ty] [%e v]) ]])
      fields
  in
  [%expr List.concat [%e B.elist ~loc parts]]

let record_pattern ~loc fields =
  B.ppat_record ~loc
    (List.map (fun f -> ({ loc; txt = Lident f.label }, B.pvar ~loc (var f))) fields)
    Closed

let record_expression ~loc fields =
  B.pexp_record ~loc
    (List.map (fun f -> ({ loc; txt = Lident f.label }, B.evar ~loc (var f))) fields)
    None

(* Binds every field from the object [mcp__fields], then [k]. *)
let decode_fields ~loc fields k =
  List.fold_right
    (fun f acc ->
       let loc = f.floc in
       let key = B.estring ~loc f.key in
       let get =
         match kind f.ty, f.dflt with
         | `Option a, _ ->
           [%expr Mcp_derive.optional [%e key] [%e conv ~suffix:"of_json" a] mcp__fields]
         | _, Some d ->
           [%expr Mcp_derive.defaulted [%e key] [%e conv ~suffix:"of_json" f.ty] [%e d]
               mcp__fields]
         | _ ->
           [%expr Mcp_derive.required [%e key] [%e conv ~suffix:"of_json" f.ty] mcp__fields]
       in
       [%expr Result.bind [%e get] (fun [%p B.pvar ~loc (var f)] -> [%e acc])])
    fields [%expr Ok [%e k]]

let schema_props ~ctx ~mode ~loc fields =
  let props =
    List.map
      (fun f ->
         let loc = f.floc in
         let s = schema ~ctx ~mode f.ty in
         let s = match f.fdoc with
           | None -> s
           | Some d -> [%expr Mcp_derive.describe [%e B.estring ~loc d] [%e s]] in
         [%expr ([%e B.estring ~loc f.key], [%e s])])
      fields
  in
  let required =
    List.filter
      (fun f ->
         match kind f.ty with
         | `Option _ -> false
         | k ->
           if mode = "in" then f.dflt = None
           else f.keep || k = `Other)
      fields
  in
  ( B.elist ~loc (List.map (fun f -> B.estring ~loc f.key) required),
    B.elist ~loc props )

(* --- one declaration ---------------------------------------------------- *)

type shape =
  | Alias of core_type
  | Record of field list
  | Enum of (string * string) list                         (* constructor, value *)
  | Tagged of string * (string * string * field list option * string option) list

let shape ~tag td =
  let loc = td.ptype_loc in
  if td.ptype_params <> [] then
    Location.raise_errorf ~loc "deriving mcp: a type with parameters is not supported";
  match td.ptype_kind, td.ptype_manifest with
  | Ptype_abstract, Some ty -> Alias ty
  | Ptype_record lds, _ -> Record (List.map field_of lds)
  | Ptype_variant cds, _ ->
    let value cd = Option.value (Attribute.get name_cd cd) ~default:(snake cd.pcd_name.txt) in
    let constant cd = match cd.pcd_args with Pcstr_tuple [] -> true | _ -> false in
    (match tag with
     | None when List.for_all constant cds ->
       Enum (List.map (fun cd -> (cd.pcd_name.txt, value cd)) cds)
     | None ->
       Location.raise_errorf ~loc
         "deriving mcp: a variant with arguments needs ~tag:\"field\""
     | Some tag ->
       Tagged
         ( tag,
           List.map
             (fun cd ->
                match cd.pcd_args with
                | Pcstr_tuple [] -> (cd.pcd_name.txt, value cd, None, doc cd.pcd_attributes)
                | Pcstr_record lds ->
                  (cd.pcd_name.txt, value cd, Some (List.map field_of lds),
                   doc cd.pcd_attributes)
                | Pcstr_tuple _ ->
                  Location.raise_errorf ~loc:cd.pcd_loc
                    "deriving mcp: a constructor takes an inline record or nothing")
             cds ))
  | _ -> Location.raise_errorf ~loc "deriving mcp: unsupported type declaration"

let construct ~loc c arg = B.pexp_construct ~loc { loc; txt = Lident c } arg
let construct_p ~loc c arg = B.ppat_construct ~loc { loc; txt = Lident c } arg

let encoder td sh =
  let loc = td.ptype_loc in
  let t = B.ptyp_constr ~loc { loc; txt = Lident td.ptype_name.txt } [] in
  let body =
    match sh with
    | Alias ty -> [%expr [%e conv ~suffix:"to_json" ty] mcp__v]
    | Record fields ->
      [%expr let [%p record_pattern ~loc fields] = mcp__v in
        `Assoc [%e encode_fields ~loc fields]]
    | Enum cs ->
      B.pexp_match ~loc [%expr mcp__v]
        (List.map
           (fun (c, v) ->
              B.case ~lhs:(construct_p ~loc c None) ~guard:None
                ~rhs:[%expr `String [%e B.estring ~loc v]])
           cs)
    | Tagged (tag, cs) ->
      B.pexp_match ~loc [%expr mcp__v]
        (List.map
           (fun (c, v, fields, _) ->
              let tagged = [%expr ([%e B.estring ~loc tag], `String [%e B.estring ~loc v])] in
              match fields with
              | None ->
                B.case ~lhs:(construct_p ~loc c None) ~guard:None
                  ~rhs:[%expr `Assoc [ [%e tagged] ]]
              | Some fields ->
                B.case ~lhs:(construct_p ~loc c (Some (record_pattern ~loc fields)))
                  ~guard:None
                  ~rhs:[%expr `Assoc ([%e tagged] :: [%e encode_fields ~loc fields])])
           cs)
  in
  [%expr fun (mcp__v : [%t t]) -> ([%e body] : Yojson.Safe.t)]

let decoder td sh =
  let loc = td.ptype_loc in
  let t = B.ptyp_constr ~loc { loc; txt = Lident td.ptype_name.txt } [] in
  let body =
    match sh with
    | Alias ty -> [%expr [%e conv ~suffix:"of_json" ty] mcp__j]
    | Record fields ->
      [%expr Result.bind (Mcp_derive.fields_of mcp__j) (fun mcp__fields ->
          [%e decode_fields ~loc fields (record_expression ~loc fields)])]
    | Enum cs ->
      let names = String.concat ", " (List.map snd cs) in
      B.pexp_match ~loc [%expr mcp__j]
        (List.map
           (fun (c, v) ->
              B.case ~lhs:[%pat? `String [%p B.pstring ~loc v]] ~guard:None
                ~rhs:[%expr Ok [%e construct ~loc c None]])
           cs
         @ [ B.case ~lhs:[%pat? mcp__other] ~guard:None
               ~rhs:[%expr Mcp_derive.fail [%e B.estring ~loc ("one of " ^ names)] mcp__other] ])
    | Tagged (tag, cs) ->
      let cases =
        List.map
          (fun (c, v, fields, _) ->
             let rhs = match fields with
               | None -> [%expr Ok [%e construct ~loc c None]]
               | Some fields ->
                 decode_fields ~loc fields
                   (construct ~loc c (Some (record_expression ~loc fields))) in
             B.case ~lhs:(B.pstring ~loc v) ~guard:None ~rhs)
          cs
        @ [ B.case ~lhs:[%pat? mcp__other] ~guard:None
              ~rhs:[%expr Error ([%e B.estring ~loc ("unknown " ^ tag ^ " ")] ^ mcp__other)] ]
      in
      [%expr Result.bind (Mcp_derive.fields_of mcp__j) (fun mcp__fields ->
          Result.bind (Mcp_derive.tag_of [%e B.estring ~loc tag] mcp__fields)
            [%e B.pexp_function_cases ~loc cases])]
  in
  [%expr fun (mcp__j : Yojson.Safe.t) -> ([%e body] : ([%t t], string) result)]

let schema_of ~ctx ~mode td sh =
  let loc = td.ptype_loc in
  match sh with
  | Alias ty -> schema ~ctx ~mode ty
  | Record fields ->
    let required, props = schema_props ~ctx ~mode ~loc fields in
    [%expr Mcp_derive.obj ~required:[%e required] [%e props]]
  | Enum cs -> [%expr Mcp_derive.enum [%e B.elist ~loc (List.map (fun (_, v) -> B.estring ~loc v) cs)]]
  | Tagged (tag, cs) ->
    let branches =
      List.map
        (fun (_, v, fields, cdoc) ->
           let required, props = match fields with
             | None -> ([%expr []], [%expr []])
             | Some fields -> schema_props ~ctx ~mode ~loc fields in
           let b = [%expr Mcp_derive.tagged ~tag:[%e B.estring ~loc tag]
               ~value:[%e B.estring ~loc v] ~required:[%e required] [%e props]] in
           match cdoc with
           | None -> b
           | Some d -> [%expr Mcp_derive.describe [%e B.estring ~loc d] [%e b]])
        cs
    in
    [%expr Mcp_derive.one_of [%e B.elist ~loc branches]]

let generate ~ctxt:_ (_rec_flag, tds) tag =
  let loc = match tds with td :: _ -> td.ptype_loc | [] -> Location.none in
  let shapes = List.map (fun td -> (td, shape ~tag td)) tds in
  let ctx =
    { group =
        List.map (fun (td, sh) ->
            (td.ptype_name.txt, match sh with Enum _ -> true | _ -> false)) shapes } in
  let binding name expr =
    B.value_binding ~loc ~pat:(B.pvar ~loc name) ~expr in
  let converters =
    List.concat_map
      (fun (td, sh) ->
         let n = td.ptype_name.txt in
         [ binding (n ^ "_to_json") (encoder td sh);
           binding (n ^ "_of_json") (decoder td sh) ])
      shapes
  in
  let schemas =
    List.concat_map
      (fun (td, sh) ->
         let n = td.ptype_name.txt in
         [ binding (n ^ "_schema_in") (schema_of ~ctx ~mode:"in" td sh);
           binding (n ^ "_schema_out") (schema_of ~ctx ~mode:"out" td sh) ])
      shapes
  in
  let codecs =
    List.map
      (fun (td, _) ->
         let n = td.ptype_name.txt in
         let e s = B.evar ~loc (n ^ s) in
         binding (n ^ "_mcp")
           [%expr { Mcp_derive.to_json = [%e e "_to_json"]; of_json = [%e e "_of_json"];
                    schema_in = [%e e "_schema_in"]; schema_out = [%e e "_schema_out"] }])
      shapes
  in
  [ B.pstr_include ~loc
      (B.include_infos ~loc
         (B.pmod_structure ~loc
            [ [%stri [@@@ocaml.warning "-39"]];
              B.pstr_value ~loc Recursive converters;
              B.pstr_value ~loc Nonrecursive schemas;
              B.pstr_value ~loc Nonrecursive codecs ])) ]

let () =
  let args = Deriving.Args.(empty +> arg "tag" (estring __)) in
  ignore
    (Deriving.add "mcp"
       ~str_type_decl:(Deriving.Generator.V2.make args generate))
