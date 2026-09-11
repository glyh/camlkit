(* The toplevel prints "val _0 : int = 42", which packs a name, a type and a
   value into one string. Toploop hands its printer an Outcometree.out_phrase
   before flattening it, so the pieces are available if we intercept the hook.

   We wrap rather than replace: utop installs its own print_out_phrase from a
   module initializer, and the text it produces is still what we show. *)

open Wire

let captured = ref Msg.No_outcome

(* Outcometree printers are Format_doc printers, not plain Format ones.
   Format_doc.compat bridges them, and exists on both 5.3 and 5.4. *)
let doc printer = Format_doc.compat printer

let to_string printer x =
  let b = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer b in
  printer ppf x;
  Format.pp_print_flush ppf ();
  String.trim (Buffer.contents b)

let name_of_item = function
  | Outcometree.Osig_value { Outcometree.oval_name; _ } -> oval_name
  | Outcometree.Osig_type ({ Outcometree.otype_name; _ }, _) -> otype_name
  | Outcometree.Osig_module (n, _, _) | Outcometree.Osig_modtype (n, _) -> n
  | Outcometree.Osig_class (_, n, _, _, _)
  | Outcometree.Osig_class_type (_, n, _, _, _) -> n
  | Outcometree.Osig_typext _ | Outcometree.Osig_ellipsis -> ""

(* For a value the useful field is its type alone; for anything else the whole
   declaration is what a reader wants. *)
let type_of_item = function
  | Outcometree.Osig_value { Outcometree.oval_type; _ } ->
    to_string (doc !Toploop.print_out_type) oval_type
  | item -> to_string (doc !Toploop.print_out_sig_item) item

let decompose = function
  | Outcometree.Ophr_eval (v, t) ->
    Msg.Value { value_type = to_string (doc !Toploop.print_out_type) t;
                value = to_string !Toploop.print_out_value v }
  | Outcometree.Ophr_signature [] -> Msg.No_outcome
  | Outcometree.Ophr_signature items ->
    Msg.Bindings
      (List.map
         (fun (item, value) ->
            Msg.{ bound = name_of_item item;
                  bound_type = type_of_item item;
                  bound_value =
                    Option.map (to_string !Toploop.print_out_value) value })
         items)
  | Outcometree.Ophr_exception (e, _) ->
    Msg.Raised
      (try Toplevel.message_of_exn e with _ -> Printexc.to_string e)

let install () =
  let previous = !Toploop.print_out_phrase in
  Toploop.print_out_phrase :=
    (fun ppf phrase ->
       captured := decompose phrase;
       previous ppf phrase)

let take () =
  let o = !captured in
  captured := Msg.No_outcome;
  o
