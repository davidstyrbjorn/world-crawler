
level_factory :: #type (world: *EntityWorld);

levels := level_factory.[create_level_1];

create_level_1 :: (world: *EntityWorld) {
  #insert -> string {
    code, success := read_entire_file("level.jai.in");
    assert(success);
    return code;
  }
}