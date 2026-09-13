let base = 0.08
let rate = function "EU" -> 0.20 | _ -> base
(* Calls rate inside its own module, which overwriting cannot reach. *)
let total ?(discount = 0.) region items =
  List.fold_left ( +. ) 0. items *. (1. +. rate region) -. discount
let rec length = function [] -> 0 | _ :: t -> 1 + length t
type pricer = string -> float
(* A constraint before `function`, which the rewrite once moved onto the match
   the cases become, so the unit did not build. *)
let flat (r : float) : pricer = function _ -> r
