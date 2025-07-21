
COLS: s16 : 40;
ROWS: s16 : 40;

tile_w: s16 = 24;
tile_h: s16 = 24;

GameState :: struct {
  edit_mode: bool = false;
  current_level: int = 0;
  glitcher_counter: float = 0.0;
  selected_entity: *Entity = null;
}
game_state: GameState;

SVector :: struct {
  x, y: s16;
}

Node :: struct {
  pos: SVector;
  g_cost: s16;
  h_cost: s16;
  f_cost: s16;
}

Cell :: struct {
  glyph: int;
  fg, bg: rl.Color;  
}
buffer: [COLS][ROWS]Cell;

directions := SVector.[
  SVector.{1, 0},
  SVector.{-1, 0},
  SVector.{0, 1},
  SVector.{0, -1},
];

/// --- BEGIN ENTITY 

Command_Type :: enum {
  PLAYER_MOVE;
  // ... add as wished
}

PlayerMove :: struct {
  old_pos: SVector;
  new_pos: SVector;
  player: *Entity;
}

Command :: struct {
  type: Command_Type;
  union {
    player_move: PlayerMove;
  }
}

EntityWorld :: struct {
  entities: [..]Entity;
  entity_groups: [NUM_ENTITY_KIND][..]*Entity;
  cached_id_to_index: Table.Table(u32, s32); 
  
  // For the logic that doesn't fit as an entity but still wants update and such
  update_systems: [..]#type (*EntityWorld, float);
  render_systems: [..]#type ();

  queued_commands: [..]Command; // Gets flushed into commands at the start of every update 
  commands: [..]Command; // Gets flushed at the end of every update

  dirty: bool; // To indicate we need to rebuild our arrays
  next_id: u32 = 0;
}

EntityInitProc :: #type (w: *EntityWorld, e: *Entity);
EntityUpdateProc :: #type (w: *EntityWorld, *Entity, dt: float);
EntityRenderProc :: #type (w: *EntityWorld, e: *Entity);

empty_init :: (_: *EntityWorld, _: *Entity) {}
empty_update :: (_: *EntityWorld, _: *Entity, _: float) {}
empty_render :: (_: *EntityWorld, _: *Entity) {}

// Mega entity struct
Entity :: struct {
  id: u32;
  init_proc: EntityInitProc = empty_init;
  update_proc: EntityUpdateProc = empty_update;
  render_proc: EntityRenderProc = empty_render;
  kind: Entity_Kind;

  pos: SVector;
  offset: Vector2;
  color: rl.Color;
  glyph: int;
  move_tick: s16;
}

NUM_ENTITY_KIND :: 4;
Entity_Kind :: enum u32 {
  PLAYER;
  ENEMY;
  WALL;
  GLITCHER;
}

entity_world_init :: (world: *EntityWorld) {
  Table.init(*world.cached_id_to_index); 
}

entity_world_deinit :: (world: *EntityWorld) {
  Table.deinit(*world.cached_id_to_index);
  array_reset(*world.entities);
  array_reset(*world.update_systems);
  array_reset(*world.render_systems);
}

entity_world_update :: (world: *EntityWorld, dt: float) {
  if world.dirty {
    entity_world_rebuild(world);
  }
  world.dirty = false;

  for world.queued_commands {
    array_add(*world.commands, it);
  }
  array_reset(*world.queued_commands);

  for world.update_systems {
    it(world, dt);
  }

  for *world.entities {
    it.update_proc(world, it, dt);
  }

  array_reset(*world.commands);
}

entity_world_push_command :: (world: *EntityWorld, command: Command) {
  array_add(*world.queued_commands, command);
}

entity_world_render :: (world: *EntityWorld) {
  for world.render_systems {
    it();
  }
  for *world.entities {
    it.render_proc(world, it);
  }
}

entity_world_clear :: (world: *EntityWorld) {
  array_reset(*world.entities);
  entity_world_rebuild(world); // rebuild instantly here
}

entity_world_add :: (world: *EntityWorld, e: Entity) {
  array_add(*world.entities, e);
  new_e := *world.entities[world.entities.count-1];
  new_e.id = world.next_id;
  world.next_id += 1;
  new_e.init_proc(world, new_e);
  world.dirty = true;
}

entity_world_remove :: (world: *EntityWorld, id: u32) {
  index, success := Table.table_find(*world.cached_id_to_index, id);
  assert(success, "Should never happen! Index should always be in the cache table");
  array_unordered_remove_by_index(*world.entities, index);
  world.dirty = true;
}

entity_world_rebuild :: (world: *EntityWorld) {
  for 0..NUM_ENTITY_KIND-1 {
    array_reset(*world.entity_groups[it]);
  }
  for *world.entities {
    array_add(*world.entity_groups[it.kind], it);
  }

  Table.table_reset(*world.cached_id_to_index);
  for i : 0..world.entities.count-1 {
    Table.table_add(*world.cached_id_to_index, world.entities[i].id, i.(s32));
  }
}

/// --- END ENTITY

color :: inline (r: u8, g: u8, b: u8, a: u8 = 255) -> rl.Color {
  return rl.Color.{r, g, b, a};
}

color_random :: (a: u8  = 255) -> rl.Color {
  r := cast(u8)(random_get() % 255);
  g := cast(u8)(random_get() % 255);
  b := cast(u8)(random_get() % 255);
  return color(r, g, b, a);
}

xy :: inline (x: s16, y: s16) -> SVector {
  return SVector.{x, y};
}

heuristic :: (p1: SVector, p2: SVector) -> s16 {
  return (abs(p1.x - p2.x) + abs(p1.y - p2.y)).(s16);
}

is_valid :: (pos: SVector) -> bool {
  return pos.x >= 0 && pos.x < COLS && pos.y >= 0 && pos.y < ROWS;
}

is_wall :: (world: *EntityWorld, pos: SVector) -> bool {
  for world.entity_groups[Entity_Kind.WALL] {
    if it.pos.x == pos.x && it.pos.y == pos.y then return false;
  }

  return true;
}

is_occupied_by_enemy :: (world: *EntityWorld, pos: SVector) -> u32, bool {
  for world.entity_groups[Entity_Kind.ENEMY] {
    if it.pos.x == pos.x && it.pos.y == pos.y then return it.id, true;
  }

  return 0, false;
}

move_enemy_towards_player :: (world: *EntityWorld, player: *Entity, enemy: *Entity) -> bool {
  // Are we already ONE cell away from the player? let's not move into them
  if abs(enemy.pos.x - player.pos.x) + abs(enemy.pos.y - player.pos.y) <= 1 then return true;

  open_list: [..]Node;
  defer array_free(open_list);
  closed: [COLS][ROWS]bool;

  came_from_pos: [COLS][ROWS]SVector;
  for y : 0..ROWS-1 {
    for x : 0..COLS-1 {
      came_from_pos[x][y] = xy(-1, -1);
    }
  }

  start := Node.{
    xy(enemy.pos.x, enemy.pos.y), 
    0,
    heuristic(enemy.pos, player.pos),
    0
  };
  start.f_cost = start.g_cost + start.h_cost;

  array_add(*open_list, start);

  found := false;
  while open_list.count > 0 {
    // Find node with lowest f cost
    current_index := 0;
    for 1..open_list.count-1 {
      if open_list[it].f_cost < open_list[current_index].f_cost then current_index = it;
    }

    current := open_list[current_index];
    array_ordered_remove_by_index(*open_list, current_index);

    // Win condition
    if current.pos.x == player.pos.x && current.pos.y == player.pos.y {
      found = true;
      break;
    }

    closed[current.pos.x][current.pos.y] = true;

    for directions {
      new_pos := xy(current.pos.x + it.x, current.pos.y + it.y);

      // Not a valid position, or already visited?
      if !is_valid(new_pos) then continue;
      if closed[new_pos.x][new_pos.y] || !is_wall(world, new_pos) then continue;
      by_id, occupied := is_occupied_by_enemy(world, new_pos);
      if occupied && by_id != enemy.id then continue; // Avoid walking into another enemy 

      tentative_g := current.g_cost + 1;
      
      // Check if already in open list with a better g cost
      in_open := false;
      for node : open_list {
        if node.pos.x == new_pos.x && node.pos.y == new_pos.y && tentative_g >= node.g_cost {
          in_open = true;
          break;
        }
      }

      if in_open then continue;

      came_from_pos[new_pos.x][new_pos.y] = current.pos;
      
      h := heuristic(new_pos, player.pos);
      array_add(*open_list, Node.{
        new_pos,
        tentative_g,
        h,
        tentative_g + h,
      });
    }
  }

  if !found then return false; // Lose condition

  // Reconstruct the path
  pos := player.pos;
  path: [..]SVector;
  defer array_free(path);

  while pos.x != enemy.pos.x || pos.y != enemy.pos.y {
    array_add(*path, pos);
    tmp := came_from_pos[pos.x][pos.y];
    if tmp.x == -1 || tmp.y == -1 then return true; // TODO: Why do we need this?
    pos = tmp;
  }

  last := path[path.count-1];
  enemy.pos.x = last.x;
  enemy.pos.y = last.y;

  return true;
}

has_line_of_sight :: (world: *EntityWorld, from: *Entity, to: *Entity, max_distance: s16) -> bool, float {
  dx := abs(to.pos.x - from.pos.x);
  dy := abs(to.pos.y - from.pos.y);
  steps := max(dx, dy);
  
  // Simple out of bounds for visibility check
  if dx > max_distance || dy > max_distance then return false, 0.0;

  x := from.pos.x;
  y := from.pos.y;
  n := 1 + dx + dy;
  x_inc := ifx to.pos.x > from.pos.x then cast(s16)1 else cast(s16)-1;
  y_inc := ifx to.pos.y > from.pos.y then cast(s16)1 else cast(s16)-1;
  error := dx - dy;

  dx *= 2;
  dy *= 2;

  distance_walked: s16 = 0;

  while n > 0 {

    if !is_wall(world, xy(x, y)) return false, 0.0; // Lose state, hard ray

    if x == to.pos.x && y == to.pos.y {
      t := 1.0 - (distance_walked.(float) / max_distance);
      return true, t; // Win state
    }

    if error > 0 {
      x += x_inc;
      error -= dy;
    } else {
      y += y_inc;
      error += dx;
    }

    distance_walked += 1;
    if distance_walked > max_distance then return false, 0.0;

    n -= 1;
  }

  return false, 0.0;
}

randomize_cell :: (cell: *Cell, $do_color: bool = true) {
  cell.glyph = cast(int)(32 + random_get() % (126-32));
  cell.bg = color(0, 0, 0, 255);

  #if do_color {
    r := cast(u8)(random_get() % 255);
    g := cast(u8)(random_get() % 255);
    b := cast(u8)(random_get() % 255);
    print("color = (%, %, %)\n", r, g, b);
    cell.fg = color(r, g, b, 255);
  }
}

clear_buffer :: () {
  for y : 0..ROWS-1 {
    for x : 0..COLS-1 {
      cell := *buffer[x][y];
      cell.fg = color(0, 0, 0, 0);
      cell.bg = color(0, 0, 0, 0);
    }
  }
}

create_wall :: (world: *EntityWorld, pos: SVector) {
  render_wall :: (world: *EntityWorld, wall: *Entity) {
    wall_cell := *buffer[wall.pos.x][wall.pos.y];
    wall_cell.fg = wall.color;

    // Light it up according to player distance
    player := world.entity_groups[Entity_Kind.PLAYER][0];
    if game_state.edit_mode {
      wall_cell.fg.a = 255;
    }
    
    wall_cell.glyph = wall.glyph;
  }

  update_wall :: (world: *EntityWorld, wall: *Entity, dt: float) {
    for world.commands {
      if it.type == .PLAYER_MOVE {
        wall.color.a = get_lit_alpha(it.player_move.player.pos, wall.pos, 9);
      }
    }
  }

  wall: Entity;
  wall.render_proc = render_wall;
  wall.update_proc = update_wall;

  wall.kind = .WALL;

  wall.pos = pos;
  wall.color = color(100, 100, 100, 255);
  wall.glyph = 35;

  entity_world_add(world, wall);
}

create_glitcher :: (world: *EntityWorld, pos_x: s16, pos_y: s16) {
  glitcher: Entity;
  glitcher.kind = .GLITCHER;

  render_glitch :: (world: *EntityWorld, glitch: *Entity) {
    glitch_cell := *buffer[glitch.pos.x][glitch.pos.y];
    glitch_cell.fg = glitch.color;
    if game_state.edit_mode then glitch_cell.fg.a = 255;
    glitch_cell.glyph = glitch.glyph;
  }

  update_glitch :: (world: *EntityWorld, glitch: *Entity, dt: float) {
    for world.commands {
      if it.type == .PLAYER_MOVE {
        glitch.color.a = get_lit_alpha(it.player_move.player.pos, glitch.pos, 9);
      }
    }
  }
  
  glitcher.render_proc = render_glitch;
  glitcher.update_proc = update_glitch;

  glitcher.pos = xy(pos_x, pos_y);
  glitcher.color = color_random();
  glitcher.glyph = cast(int)(32 + random_get() % (126-32));

  entity_world_add(world, glitcher);
}

create_enemy :: (world: *EntityWorld, pos: SVector) {
  enemy: Entity;
  enemy.kind = .ENEMY;

  enemy_render :: (world: *EntityWorld, enemy: *Entity) {
    enemy_cell := *buffer[enemy.pos.x][enemy.pos.y];
    enemy_cell.fg = enemy.color;

    if game_state.edit_mode then enemy_cell.fg.a = 255;

    enemy_cell.glyph = enemy.glyph;
  }

  enemy_update :: (world: *EntityWorld, enemy: *Entity, dt: float) {
    for world.commands {
      if it.type == .PLAYER_MOVE {
        sees_player, t := has_line_of_sight(world, enemy, it.player_move.player, 8);
        if sees_player {
          enemy.color = color(255, 20, 50, 255);
        } else {
          enemy.color = color(90, 90, 90, 255);
        }

        enemy.color.a = get_lit_alpha(it.player_move.player.pos, enemy.pos, 9);

        // Move?
        enemy.move_tick += 1;
        if enemy.move_tick % 2 == 0 && has_line_of_sight(world, enemy, it.player_move.player, 8) {
          move_enemy_towards_player(world, it.player_move.player, enemy);
        }
      }
    }
  }

  enemy.render_proc = enemy_render;
  enemy.update_proc = enemy_update;

  enemy.pos = pos;
  enemy.move_tick = 0;
  enemy.color = color(90, 90, 90, 255);
  enemy.glyph = 69;

  entity_world_add(world, enemy);
}

create_player :: (world: *EntityWorld) {
  move_player :: (world: *EntityWorld, player: *Entity, dx: s16, dy: s16) {
    new_pos := xy(player.pos.x + dx, player.pos.y + dy);
    // Check for wall
    if (!game_state.edit_mode && !is_wall(world, new_pos)) || !is_valid(new_pos) then return;

    command: Command;
    command.type = .PLAYER_MOVE;
    command.player_move = PlayerMove.{player.pos, new_pos, player};
    entity_world_push_command(world, command);

    player.pos = new_pos;
  }
 
  update_player :: (world: *EntityWorld, player: *Entity, dt: float) {
    if rl.IsKeyPressed(.KEY_D) move_player(world, player, 1, 0);
    if rl.IsKeyPressed(.KEY_A) move_player(world, player, -1, 0);
    if rl.IsKeyPressed(.KEY_S) move_player(world, player, 0, 1);
    if rl.IsKeyPressed(.KEY_W) move_player(world, player, 0, -1);

    if rl.IsKeyPressed(.KEY_C) {
      // create_wall(world, xy(player.pos.x, player.pos.y)); // Give birth, right here, right now
      // create_enemy(world, xy(player.pos.x, player.pos.y)); // Give birth, right here, right now
      create_glitcher(world, player.pos.x, player.pos.y); // Give birth, right here, right now
    }

    if rl.IsKeyPressed(.KEY_TAB) then game_state.edit_mode = !game_state.edit_mode;

    if rl.IsKeyPressed(.KEY_P) then print_level(world);
  }

  render_player :: (world: *EntityWorld, player: *Entity) {
    player_cell := *buffer[player.pos.x][player.pos.y];
    player_cell.fg = color(255, 0, 255, 255);
    player_cell.glyph = player.glyph;
  }

  player: Entity;
  player.kind = .PLAYER;
  player.update_proc = update_player;
  player.render_proc = render_player;

  player.pos = xy(1, 1);
  player.glyph = 64;

  entity_world_add(world, player);
}

print_level :: (world: *EntityWorld) {
  builder: String_Builder;
  init_string_builder(*builder);
  for world.entity_groups[Entity_Kind.ENEMY] {
    append(*builder, sprint("create_enemy(world, xy(%, %));\n", it.pos.x, it.pos.y));
  }
  for world.entity_groups[Entity_Kind.WALL] {
    append(*builder, sprint("create_wall(world, xy(%, %));\n", it.pos.x, it.pos.y));
  }
  for world.entity_groups[Entity_Kind.GLITCHER] {
    append(*builder, sprint("create_glitcher(world, %, %);\n", it.pos.x, it.pos.y));
  }

  file, success := file_open("./level.jai.in", true);
  assert(success, "Failed to open level file for writing!");
  defer file_close(*file);
  file_write(*file, *builder);

  print("Saved level!\n");
}

get_lit_alpha :: (light_pos: SVector, from: SVector, dist_to_dark: s16) -> u8 {
  euclidian_distance := abs(light_pos.x - from.x) + abs(light_pos.y - from.y);
  if euclidian_distance > dist_to_dark {
    return 0;
  }
  t := 1.0 - euclidian_distance.(float)/dist_to_dark;
  return (255 * t).(u8);
}

glitcher_system :: (world: *EntityWorld, dt: float) {
  GLITCHER_UPDATE :: 0.8;   
  game_state.glitcher_counter += dt;
  if game_state.glitcher_counter >= GLITCHER_UPDATE {
    for world.entity_groups[Entity_Kind.GLITCHER] {
      if random_get() % 100 < 10 {
        it.glyph = cast(int)(32 + random_get() % (126-32));
      }
    }
  }                               
}

edit_system :: (world: *EntityWorld, dt: float) {
  if !game_state.edit_mode then return;

  if game_state.selected_entity != null {
    e := game_state.selected_entity;
    height := rl.GetScreenHeight().(float);
    rl.GuiLabel(rl.Rectangle.{10, height-100, 200, 50}, to_c_string(sprint("ID = %, Kind = %", e.id, e.kind)));
    if rl.GuiButton(rl.Rectangle.{10, height-50, 100, 50}, "Delete") {
      entity_world_remove(world, game_state.selected_entity.id);
      game_state.selected_entity = null;
      return;
    }

    // Draw a rect over the selected tile
    pos := xy((e.pos.x*tile_w).(float), (e.pos.y*tile_h).(float));
    rl.DrawRectangle(pos.x.(s32), pos.y.(s32), tile_w, tile_h, color(20, 255, 30, 100));
  }
  
  if rl.IsMouseButtonPressed(.MOUSE_BUTTON_LEFT) {
    mouse_pos := rl.GetMousePosition();
    print("Mouse position = %\n", mouse_pos);
    mouse_pos.x /= rl.GetScreenWidth();
    mouse_pos.y /= rl.GetScreenHeight();

    grid_pos: SVector;
    grid_pos.x = (mouse_pos.x * COLS).(s16); 
    grid_pos.y = (mouse_pos.y * ROWS).(s16); 
    print("Grid position = %\n", grid_pos);

    // Check if we can find a selectable entity
    for world.entity_groups[Entity_Kind.WALL] {
      if it.pos.x == grid_pos.x && it.pos.y == grid_pos.y {
        game_state.selected_entity = it;
      }
    }
    for world.entity_groups[Entity_Kind.ENEMY] {
      if it.pos.x == grid_pos.x && it.pos.y == grid_pos.y {
        game_state.selected_entity = it;
      }
    }
  }

  if rl.IsMouseButtonPressed(.MOUSE_BUTTON_RIGHT) {
    game_state.selected_entity = null;
  }
}

main :: () {
  rl.InitWindow(COLS * tile_w, ROWS * tile_h, "Glyph Test");
  rl.SetTargetFPS(60);
  font := rl.LoadFontEx("./font.ttf", tile_w, null, 0);

  world: EntityWorld;
  entity_world_init(*world);
  array_add(*world.update_systems, glitcher_system);

  create_player(*world);
  levels[game_state.current_level](*world);

  entity_world_rebuild(*world);

  command: Command;
  command.type = .PLAYER_MOVE;
  player := world.entity_groups[Entity_Kind.PLAYER][0];
  command.player_move = PlayerMove.{player.pos, player.pos, player};
  entity_world_push_command(*world, command);

  rl.GuiSetStyle(0, rl.GuiDefaultProperty.TEXT_SIZE.(s32), 20);

  while !rl.WindowShouldClose() {
    entity_world_update(*world, rl.GetFrameTime());

    clear_buffer();
    entity_world_render(*world);

    rl.BeginDrawing();
      rl.ClearBackground(rl.BLACK);
      // Draw the buffer
      for y : 0..ROWS-1 {
        for x : 0..COLS-1 {
          cell := buffer[x][y];
          rl.DrawRectangle(x*tile_w, y*tile_h, tile_w, tile_h, cell.bg);

          // Draw the glyph
          glyph_index := rl.GetGlyphIndex(font, cell.glyph.(s32));
          rec := font.recs[glyph_index];
          pos := xy((x*tile_w).(float), (y*tile_h).(float));
          rl.DrawTextureRec(font.texture, rec, pos, cell.fg);
        }
      }

      edit_system(*world, rl.GetFrameTime());

    rl.EndDrawing();
  }
}

#import "Random";
#import "Math";
#import "Basic";
#import "File";
Table :: #import "Hash_Table";
rl :: #import "raylib";

#load "levels.jai";