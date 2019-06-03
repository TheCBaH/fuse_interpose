(*
#load "unix.cma";;

#load "bigarray.cma";;
*)

type time = float

module Dir = struct
  type dir = elt list
  and elt =
    {
      name: String.t;
      mtime: time;
      children: dir
    }

  let element name st children =
    {name;mtime=st.Unix.st_mtime;children}

  let name e =
    e.name
  let mtime e =
    e.mtime

  let add t elt =
    elt::t

  let children e =
    e.children

  let empty = []

  let length d = List.length d

  let rec fold_left f a t =
    let a = List.fold_left  f a t in
    List.fold_left (fun a e ->
        fold_left f a e.children) a t

  let fold_left_level f a t =
    List.fold_left  f a t

  let fold_left_depth f a t =
    List.fold_left (fun a e ->
        List.fold_left f a e.children) a t
end

let rec scan_dir root =
  scan_dir_aux root ""
and scan_dir_aux root path =
  let base = path |> Filename.concat root in
  let elts = base |> Sys.readdir in
  Array.fold_left (fun t name ->
      let st = name |> Filename.concat base |> Unix.lstat in
      match st.Unix.st_kind with
      | Unix.S_DIR ->
         let path = name |> Filename.concat path in
         let dirs = path |> scan_dir_aux root in
          dirs |> Dir.element name st |> Dir.add t
      | _ ->
         [] |> Dir.element name st |> Dir.add t
    ) Dir.empty elts


module StrMap = Map.Make(String)
          (*
let _ = Dir.fold_left
          (fun (entry_off,string_off,strings,offsets) e ->
            let (str_loc,strings) =
              let name = Dir.name e in
              match StrMap.find_opt name strings with
              | Sone str_loc -> (str_loc,strings)
              | None -> (str_loc + (String.len name_)
                                     (StrMap.add add name str_loc) in
                         let offsets =
            *)
let align_entry n =
  let align = 4 in
  let n = n + (align - 1) in
  n - ( n mod align)

let place_strings (str_off,strings) d =
  let (str_off,strings) =
    List.fold_left
      (fun (str_off,strings) e ->
        let name = Dir.name e in
        if StrMap.mem name strings then
          str_off,strings
        else str_off + 1 + (String.length name),
             (StrMap.add name str_off strings)
      )
      (str_off,strings)d in
  (align_entry str_off, strings)

type entry =
  Len of int
| Entry of string*time*int

let entry_size = 4 + 4 + 4

let header_offset = 16

let rec place_dir d offset =
  place_level_aux (offset,StrMap.empty,[]) d
and place_level_aux (data_off,strings,entries) d =
  let field_off = data_off in
  let length = Dir.length d in
  let entries = (field_off, Len length) :: entries
  and field_off = field_off + 4 in
  let data_off = field_off + (length * entry_size) in
  let d = Dir.fold_left_level (fun d e -> e::d) [] d in
  let d = List.sort (fun e e' -> e' |> Dir.name |> String.compare (Dir.name e)) d in
  let (data_off,strings) = place_strings (data_off,strings) d in
  fst (List.fold_left (fun (s,field_off) e ->
           let (dir_off,s) = match Dir.children e with
               [] ->
                (0,s)
             | d ->
                let (data_off,_,_) = s in
                let s = place_level_aux s d  in
                (data_off,s) in
           let (data_off,strings,entries) = s in
           let entries  = (field_off, (Entry (Dir.name e,Dir.mtime e,dir_off)))::entries
           and field_off = field_off + entry_size in
           ((data_off,strings,entries),field_off)
         )  ((data_off,strings,entries),field_off) d)

let write_uint8 (a:(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t) offset value =
  Bigarray.Array1.set a offset value

let write_byte a offset value =
  write_uint8 a offset  (value land 0xFF)

let write_uint32 a offset value =
  write_byte a offset value;
  write_byte a (offset+1) (value lsr 8);
  write_byte a (offset+2) (value lsr 16);
  write_byte a (offset+3) (value lsr 24)

let write_string a off value =
  let len = String.length value in
  for i=0 to len - 1 do
    write_byte a (off+i) (Char.code (String.get value i))
  done

let read_uint8 (a:(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t) offset =
  Bigarray.Array1.get a offset

let read_uint32 a offset =
  (read_uint8 a offset)
  lor ((read_uint8 a (offset+1)) lsl 8 )
  lor ((read_uint8 a (offset+2)) lsl 16 )
  lor ((read_uint8 a (offset+3)) lsl 24 )

let read_string a off =
  let s = Bytes.create 256 in
  let rec read_string_aux a s off n =
    let ch = read_uint8 a (off+n) in
    if ch != 0 then begin
        ch |> Char.chr |> Bytes.set s n;
        read_string_aux a s off (succ n)
      end else
      String.sub s 0 n
  in
  read_string_aux a s off 0

let write_dir dir =
  let data_off,strings,entries = place_dir dir header_offset in
  let buf = Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout data_off in
  Bigarray.Array1.fill buf 0;
  let min_mtime = Dir.fold_left (fun a e -> e |> Dir.mtime |> min a) max_float dir in
  write_string buf 0 "mtim0.1";
  min_mtime |> int_of_float |> write_uint32 buf 8;
  List.iter (fun (o,e) ->
      match e with
      | Len n ->
         write_uint32 buf o n
      | Entry (s,mtime,n) ->
         let soff = StrMap.find s strings
         and mtime = mtime -. min_mtime in
         write_uint32 buf o soff;
         write_uint32 buf (o+4) (int_of_float mtime);
         write_uint32 buf (o+8) n
    ) entries;
  StrMap.iter (fun name o -> write_string buf o name) strings;
  buf

let write_buf fname buf =
  let oc = open_out_bin fname in
  let len = Bigarray.Array1.dim buf in
  for i=0 to len -1 do
    i |> Bigarray.Array1.get buf |> output_byte oc
  done;
  close_out oc

let print_buf print_mtime printer buf =
  let off = header_offset in
  let debug = false in
  let base_mtime = float_of_int (read_uint32 buf 8) in
  let rec print_one_level root off =
    if debug then
      printer(Printf.sprintf "level root:%s off:%#x" root off);
    let dir_len = read_uint32 buf off
    and off = off + 4 in
    if debug then
      printer(Printf.sprintf "dir_len %d" dir_len);
    print_one_level_aux root off dir_len 0
  and print_one_level_aux root off dir_len n =
    if n < dir_len then begin
        let str_off = read_uint32 buf off
        and mtime = read_uint32 buf (off+4)
        and children = read_uint32 buf (off+8) in
        if debug then
          printer(Printf.sprintf "root:%s off:%#x str_off:%#x %d/%d" root off str_off n dir_len);
        let off = off + entry_size in
        let name = read_string buf str_off in
        let path = Filename.concat root name in
        let mtime_str =
           if print_mtime then
            let mtime = float_of_int mtime +. base_mtime in
            let tm = Unix.localtime mtime in
            Printf.sprintf " %02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
           else
             "" in
        printer (Printf.sprintf "%s%s" path mtime_str);
        if children != 0 then
          print_one_level path children;
        n |> succ |> print_one_level_aux root off dir_len
      end in
  print_one_level "" off

let create_db path db =
  let dirs = scan_dir path in
  let count = Dir.fold_left (fun n _ -> succ n) 0 dirs in
  Printf.printf "Scanned directory %s with %u entries\n" path count;
  dirs |> write_dir |> write_buf db

let print_db print_mtime db =
  let fd = Unix.openfile db [Unix.O_RDONLY] 0 in
  let buf = Bigarray.Array1.map_file fd Bigarray.int8_unsigned Bigarray.c_layout
              false (-1) in
  print_buf print_mtime print_endline buf;
  Unix.close fd

let main () =
  let path = ref ""
  and db = ref ""
  and print_mtime = ref false
  and print = ref false in
  let options = [
      "--path",Arg.Set_string path,"Path to scan and write mtime to the database";
      "--db",Arg.Set_string db,"Database to store mtime";
      "--print-mtime",Arg.Set print_mtime,"Print mtime";
      "--print",Arg.Set print,"Print existing database";
    ] in
  let usage = "Tool to read mtime of the directory tree and write it to the database" in
  Arg.parse options ignore usage;
  if !print then
    print_db !print_mtime !db
  else begin
    if !db = "" || !path = "" then begin
        print_endline "Both database and path must be specified";
        Arg.usage options usage;
        exit 1
      end;
    create_db !path !db
    end

let () = main ()

(*
let d = scan_dir "/usr/share"
      (*
let d = scan_dir "/usr/lib/mime"
let d = scan_dir "/usr/share/man"
let d = scan_dir "/usr/share/git-core"
let d = scan_dir "/usr/share/X11"
       *)

let _ = d |> Dir.fold_left_level (fun d e -> e::d) []  |> place_strings (0,StrMap.empty) |> snd |> StrMap.bindings


let _ = List.hd d

let _ =
  let (data_off,strings,entries) = place_dir d 0 in
  ignore data_off;
  1 |> (List.sort (fun (o,_) (o',_) -> o - o') entries |> List.nth) |> ignore;
  (List.sort (fun (o,_) (o',_) -> o - o') entries),
  strings |> StrMap.bindings |> List.sort (fun (_,o) (_,o') -> o - o')

let min_mtime = Dir.fold_left (fun a e -> e |> Dir.mtime |> min a) max_float d
let max_mtime = Dir.fold_left (fun a e -> e |> Dir.mtime |> max a) min_float d
let rsnge_mtime =  (max_mtime -. min_mtime) |> int_of_float |> Printf.sprintf "%#x"


let count = Dir.fold_left (fun n _ -> succ n) 0 d

let b = write_dir d

let _ = write_buf "mtime.dat" b

let _ =
  let l = ref [] in
  print_buf  (fun s ->
      (* print_endline s; *)
      l := s::!l) b;
  List.rev !l

let _ = print_db "mtime.dat"

 *)
