open Batteries
open Stdint
open Dessser

module C = BackEndCPP

module DS1 = DesSer (RowBinary.Des (C)) (HeapValue.Ser (C))
module DS2 = DesSer (HeapValue.Des (C)) (SExpr.Ser (C)) (*(RamenRingBuffer.Ser (C))*)

let run_cmd cmd =
  match Unix.system cmd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      Printf.sprintf "%s failed with code %d\n" cmd code |>
      failwith
  | Unix.WSIGNALED s ->
      Printf.sprintf "%s killed with signal %d" cmd s |>
      failwith
  | Unix.WSTOPPED s ->
      Printf.sprintf "%s stopped by signal %d" cmd s |>
      failwith

let compile_output optim output =
  let mode = [ `create ; `excl ; `text ] in
  let fname =
    File.with_temporary_out ~mode ~suffix:".cpp" (fun oc fname ->
      Printf.fprintf oc "#include \"runtime.h\"\n\n" ;
      C.print_output oc output ;
      fname) in
  Printf.printf "Output in %s\n%!" fname ;
  let cmd =
    Printf.sprintf "g++ -std=c++17 -g -O%d -W -Wall -I direct %s examples/rowbinary2sexpr.cpp -o examples/rowbinary2sexpr" optim fname in
  run_cmd cmd


let () =
  let typ =
    let nullable = true in
    Types.(
      make (TTup [|
        make TString ;
        make TU64 ;
        make TU64 ;
        make TU8 ;
        make TString ;
        make TU8 ;
        make TString ;
        make ~nullable TU32 ;
        make ~nullable TU32 ;
        make TU64 ;
        make TU64 ;
        make TU32 ;
        make TU32 ;
        make ~nullable TU32 ;
        make ~nullable TString ;
        make ~nullable TU32 ;
        make ~nullable TString ;
        make ~nullable TU32 ;
        make ~nullable TString ;
        make TU16 ;
        make TU16 ;
        make TU8 ;
        make TU8 ;
        make ~nullable TU32 ;
        make ~nullable TU32 ;
        make TU32 ;
        make TString ;
        make TU64 ;
        make TU64 ;
        make TU64 ;  (* Should be U32 *)
        make TU64 ;  (* Should be U32 *)
        make TU64 ;
        make TU64 ;
        make ~nullable TString
      |])) in
  let output = C.make_output () in
  let _read_tuple =
    C.print_function2 output t_pair_ptrs Types.(make TPointer) Types.(make TPointer) (fun oc src dst ->
      C.comment oc "Convert from RowBinary into a heap value:" ;
      let dummy = Identifier.pointer () in (* Will be ignored by HeapValue.Ser *)
      let src, heap_value = DS1.desser typ oc src dummy in
      C.comment oc "Now convert the heap value into an SExpr:" ;
      let _, dst = DS2.desser typ oc heap_value dst in
      C.make_tuple oc t_pair_ptrs [| src ; dst |]) in
  let optim = 3 in
  compile_output optim output
