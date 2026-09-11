(* The names a phrase bound and their types, as data.

   The toplevel prints "val f : int -> int = <fun>", which a reader can parse
   but should not have to. Toploop hands its printer an
   Outcometree.out_phrase before flattening it, so the pieces are available if
   we intercept the hook. We wrap rather than replace it: the text it produces
   is still what we show.

   Names and types only. An earlier version also carried a kind and a value.
   The kind could only ever say "bindings" or "nothing", which is just whether
   the rendering is empty, and the value duplicated the rendering exactly - a
   forty-element list appeared twice in full. Both were measured and removed;
   this is the half that carries what the transcript makes you parse. *)

open Wire

let captured = ref ([] : Msg.binding list)

let to_string printer x =
  let b = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer b in
  printer ppf x;
  Format.pp_print_flush ppf ();
  String.trim (Buffer.contents b)

(* Outcometree printers are Format_doc printers, not plain Format ones. *)
let doc printer = Format_doc.compat printer

let name_of_item = function
  | Outcometree.Osig_value { Outcometree.oval_name; _ } -> oval_name
  | Outcometree.Osig_type ({ Outcometree.otype_name; _ }, _) -> otype_name
  | Outcometree.Osig_module (n, _, _) | Outcometree.Osig_modtype (n, _) -> n
  | Outcometree.Osig_class (_, n, _, _, _)
  | Outcometree.Osig_class_type (_, n, _, _, _) -> n
  | Outcometree.Osig_typext _ | Outcometree.Osig_ellipsis -> ""

(* For a value the useful field is its type alone. For anything else the whole
   declaration is the type: a module's is its signature, which is exactly what
   a caller would otherwise have to read out of the transcript. *)
let type_of_item = function
  | Outcometree.Osig_value { Outcometree.oval_type; _ } ->
    to_string (doc !Toploop.print_out_type) oval_type
  | item -> to_string (doc !Toploop.print_out_sig_item) item

let decompose = function
  | Outcometree.Ophr_signature items ->
    List.map
      (fun (item, _value) ->
         Msg.{ bound = name_of_item item; bound_type = type_of_item item })
      items
  | Outcometree.Ophr_eval (_, t) ->
    [ Msg.{ bound = ""; bound_type = to_string (doc !Toploop.print_out_type) t } ]
  | Outcometree.Ophr_exception _ -> []

let install () =
  let previous = !Toploop.print_out_phrase in
  Toploop.print_out_phrase :=
    fun ppf phrase ->
      captured := decompose phrase;
      previous ppf phrase

let take () =
  let b = !captured in
  captured := [];
  b
