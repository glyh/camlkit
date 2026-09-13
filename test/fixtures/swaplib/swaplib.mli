val rate : string -> float
val total : ?discount:float -> string -> float list -> float
val length : 'a list -> int
val base : float
type pricer = string -> float
val flat : float -> pricer
