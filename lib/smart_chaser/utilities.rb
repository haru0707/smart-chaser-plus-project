class SmartChaser
  def best_retreat_direction(grid, enemy_positions)
    return nil if enemy_positions.nil? || enemy_positions.empty?

    candidates = DIRECTIONS.keys.reject do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      coord = coordinate_in_direction(dir)
      status = coord ? trap_status(coord) : nil
      
      # 安全確認を追加
      unsafe = coord && !safe_position_against_enemies?(coord, grid)

      tile == TILE_BLOCK || tile == TILE_CHARACTER ||
        [:confirmed_trap, :pending_search, :suspected_trap].include?(status) ||
        (coord && trap_tile?(coord)) ||
        trapkaihi_suspected?(grid, dir) || unsafe
    end
    return nil if candidates.empty?

    current_distance = enemy_positions.map { |pos| manhattan_distance(@position, pos) }.min || 0

    scored = candidates.filter_map do |dir|
      coord = coordinate_in_direction(dir)
      next unless coord
      next if trap_tile?(coord)

      min_distance = enemy_positions.map { |pos| manhattan_distance(coord, pos) }.min || 0
      visit_penalty = @visit_counts[coord] * 0.3
      recent_penalty = (@recent_moves.last(4).count(dir) || 0) * 0.2
      
      # 広い空間への逃走を優先：移動先のエリアサイズを評価
      # 袋小路に追い詰められるのを防ぐため、空間の広さを重視
      area_size = memoized_space_size(@world, coord)
      area_bonus = [area_size, 10].min * 0.5  # 最大5ポイント（10マス以上は同じ）
      
      # 隣接する空きマス数も考慮（即座の移動選択肢）
      free_neighbors = free_neighbor_count(coord, [opposite_of(dir)])
      freedom_bonus = free_neighbors * 0.3
      
      score = min_distance + area_bonus + freedom_bonus - visit_penalty - recent_penalty

      { dir: dir, score: score, distance: min_distance, area: area_size }
    end

    return nil if scored.empty?

    # 敵から離れる方向を優先、ただし狭い空間は避ける
    improved = scored.select { |entry| entry[:distance] > current_distance }
    
    # 広い空間がある場合は広い方を優先
    if improved.any?
      # 距離が改善される中で最も広い空間に逃げる
      target = improved
    else
      # 距離が改善されない場合でも、広い空間を選ぶ
      target = scored
    end
    
    target.max_by { |entry| entry[:score] }[:dir]
  end

  def manhattan_distance(a, b)
    return Float::INFINITY if a.nil? || b.nil?
    (a[0] - b[0]).abs + (a[1] - b[1]).abs
  end

  def push_recent_vision(vision)
    sig = vision ? vision.join(',') : nil
    @recent_visions.unshift(sig)
    @recent_visions.pop if @recent_visions.size > 8
  end

  def stuck_here?
    return false if @recent_visions.size < 4

    # 1. 視界ベースの検出（既存ロジック）
    most_common = @recent_visions
                  .group_by { |v| v }
                  .transform_values(&:size)
                  .max_by { |_, count| count }
    vision_stuck = most_common && most_common[1] >= 3

    # 2. 往復パターンの検出（新規）
    oscillation_stuck = detect_oscillation?

    if vision_stuck || oscillation_stuck
      @stuck_counter += 1
      true
    else
      @stuck_counter = 0
      false
    end
  end

  # 往復パターン（A-B-A-B）を検出
  # 直近8手で同じ2つの方向を交互に繰り返しているかチェック
  def detect_oscillation?
    return false if @recent_moves.size < 6
    
    last_moves = @recent_moves.last(8)
    unique_dirs = last_moves.uniq
    
    # 2つの方向のみ使用している場合
    return false unless unique_dirs.size == 2
    
    # それらが互いに逆方向かチェック
    dir_a, dir_b = unique_dirs
    opposite_pair = (opposite_of(dir_a) == dir_b)
    
    return false unless opposite_pair
    
    # パターンがA-B-A-BまたはB-A-B-Aかチェック
    # 交互に現れている回数をカウント
    alternating_count = 0
    (1...last_moves.size).each do |i|
      alternating_count += 1 if last_moves[i] != last_moves[i - 1]
    end
    
    # 80%以上が交互なら往復と判定
    alternating_count >= (last_moves.size - 1) * 0.8
  end

  def break_stuck_choice(grid)
    candidates = DIRECTIONS.keys.select do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      (tile == TILE_EMPTY || tile == TILE_ITEM) && dir != opposite_of(@last_direction)
    end
    candidates.reject! { |dir| would_trap_on_move?(dir, grid) }
    return nil if candidates.empty?

    counts = @recent_moves.tally
    candidates.min_by do |dir|
      coord = coordinate_in_direction(dir)
      visit_count = coord ? @visit_counts[coord] : Float::INFINITY
      [visit_count, counts[dir] || 0]
    end
  end

  def pending_trap_search_direction
    pending = @trap_checks.values.select do |entry|
      entry[:status] == :pending_search && entry[:direction]
    end
    return nil if pending.empty?

    pending.min_by { |entry| entry[:requested_turn] || -Float::INFINITY }[:direction]
  end

  def choose_search_direction(enemy_dirs)
    pending_dir = pending_trap_search_direction
    return pending_dir if pending_dir

    # 敵がいる場合は敵の方を向く（既存ロジック）
    return enemy_dirs.first if enemy_dirs.any?

    # 未探索エリアが多い方向を探す
    frontier_dir = best_search_direction_for_frontier
    return frontier_dir if frontier_dir

    @last_direction || :up
  end

  def best_search_direction_for_frontier
    # 各方向の未探索マス数をカウントし、最大のものを選ぶ
    # ただし、すべて0の場合は nil を返してデフォルト動作に任せる（あるいはランダム）
    scored = DIRECTIONS.keys.map { |dir| [dir, count_unknowns_in_line(dir)] }
    best = scored.max_by { |_, count| count }
    
    return nil if best.nil? || best[1] == 0
    best[0]
  end

  def count_unknowns_in_line(direction)
    delta = DIRECTION_DELTAS[direction]
    return 0 unless delta
    
    (1..9).count do |dist|
      coord = [@position[0] + delta[0] * dist, @position[1] + delta[1] * dist]
      @world[coord_key(coord)].nil?
    end
  end

  def prioritize_by_last_move(directions)
    return @last_direction if @last_direction && directions.include?(@last_direction)

    directions.first
  end

  # 複数の隣接アイテムから、他のアイテムをトラップにしない方向を選択
  # アイテムを取得すると元の位置にブロックができるため、他のアイテムが罠になる可能性がある
  # また、直線移動を維持するため、前回の移動方向を優先する
  # さらに、今まで取ったアイテムに隣接するものを優先する
  def choose_best_adjacent_item_direction(item_dirs, grid)
    return nil if item_dirs.nil? || item_dirs.empty?

    # 3つ以上直線に並んだアイテムの中央を取ろうとしている場合はスキップ
    # 端に向かうためにnilを返す（best_item_targetで端を選択させる）
    if item_dirs.size == 1
      dir = item_dirs.first
      if adjacent_item_is_middle_of_line?(dir, grid)
        # 中央のアイテムなのでスキップ、端に向かう
        return nil
      end
      return prioritize_by_last_move(item_dirs)
    end

    # 各方向について、取得後に他のアイテムがトラップになるかをシミュレート
    safe_dirs = []
    trap_creating_dirs = []

    item_dirs.each do |dir|
      if would_create_trap_for_other_items?(dir, item_dirs, grid)
        trap_creating_dirs << dir
      else
        safe_dirs << dir
      end
    end

    # トラップを作らない方向があればそれを優先
    if safe_dirs.any?
      # 安全な方向の中で最適なものを選択
      return prioritize_item_by_continuity(safe_dirs, grid)
    end

    # 全てのアイテムを取ると何かがトラップになる場合はランダムに選択
    STDERR.puts "[smart] 全ての隣接アイテム取得でトラップが発生するため、ランダム選択"
    item_dirs.sample
  end

  # アイテム選択の優先順位:
  # 1. 現在位置に隣接するアイテム（item_dirs自体がすべて隣接アイテム）を最優先
  # 2. 今まで取ったアイテム（ブロックになった場所）に隣接するアイテム
  # 3. 先にさらにアイテムがある方向
  # 注: トラップ回避は choose_best_adjacent_item_direction で事前にフィルタリング済み
  def prioritize_item_by_continuity(item_dirs, grid)
    return item_dirs.first if item_dirs.empty?

    # item_dirsはすべて現在位置に隣接するアイテム方向
    # その中で、自分が今まで取ったアイテム（@self_placed_blocks）に隣接するものを優先

    # 1. 自分が置いたブロック（取得済みアイテム）に隣接するアイテムを優先
    # これにより、連続したアイテム列を効率的に取得できる
    adjacent_to_placed = item_dirs.select do |dir|
      item_coord = coordinate_in_direction(dir)
      next false unless item_coord
      is_adjacent_to_placed_blocks?(item_coord)
    end

    if adjacent_to_placed.any?
      # 隣接アイテムの中で、さらに先にアイテムがある方向を優先
      return prioritize_straight_line_item(adjacent_to_placed, grid)
    end

    # 2. 先にさらにアイテムがある方向を優先
    prioritize_straight_line_item(item_dirs, grid)
  end

  # 指定座標が自分で置いたブロック（アイテム取得でできたブロック含む）に隣接しているか
  def is_adjacent_to_placed_blocks?(coord)
    return false unless coord
    return false if @self_placed_blocks.nil? || @self_placed_blocks.empty?

    DIRECTION_DELTAS.each_value do |dx, dy|
      neighbor = [coord[0] + dx, coord[1] + dy]
      neighbor_key = coord_key(neighbor)
      return true if @self_placed_blocks.include?(neighbor_key)
    end

    false
  end

  # 直線上のアイテムを優先して選択
  # 前回の移動方向にアイテムがあればそれを優先し、直線移動を維持
  def prioritize_straight_line_item(item_dirs, grid)
    return item_dirs.first if item_dirs.empty?

    # 前回の移動方向にアイテムがあれば最優先
    if @last_direction && item_dirs.include?(@last_direction)
      return @last_direction
    end

    # 前回の方向がない場合、直線上にさらにアイテムがある方向を優先
    # 3つ以上並んでいる場合は端から取るようにする
    best_dir = item_dirs.max_by do |dir|
      score = 0
      coord = coordinate_in_direction(dir)
      next 0 unless coord

      # その方向の先にアイテムが続いているかチェック
      items_ahead = count_items_in_direction(coord, dir)
      # 反対方向にもアイテムがあるかチェック（自分の位置から見て）
      items_behind = count_items_in_direction(@position, opposite_of(dir))

      total_line_length = 1 + items_ahead + items_behind  # 取ろうとしているアイテム含む

      if total_line_length >= 3
        # 3つ以上並んでいる場合は端を優先
        # 端 = 先にアイテムがない方向
        if items_ahead == 0
          # この方向は端（先にアイテムがない）→ 高優先
          score += 20
        elsif items_behind == 0
          # 反対方向にアイテムがない = これが端
          score += 20
        else
          # 中央のアイテム → 低優先（避ける）
          score -= 10
        end
      else
        # 3つ未満の場合は従来通り先にアイテムがある方向を優先
        next_coord = coordinate_from(coord, dir)
        if next_coord
          next_tile = @world[coord_key(next_coord)]
          score += 10 if next_tile == TILE_ITEM
          score += 2 if next_tile == TILE_EMPTY
        end
      end
      score
    end

    best_dir || item_dirs.first
  end

  # 指定座標から指定方向に連続するアイテム数をカウント
  def count_items_in_direction(start_coord, direction)
    return 0 unless start_coord && direction

    count = 0
    current = start_coord

    10.times do  # 最大10マス先まで
      next_coord = coordinate_from(current, direction)
      break unless next_coord

      tile = @world[coord_key(next_coord)]
      break unless tile == TILE_ITEM

      count += 1
      current = next_coord
    end

    count
  end

  # 隣接アイテムが3つ以上の直線の中央にあるかを判定
  # 中央なら端に向かうべき
  def adjacent_item_is_middle_of_line?(dir, grid)
    item_coord = coordinate_in_direction(dir)
    return false unless item_coord

    # アイテムから4方向すべてをチェックして、直線を検出する
    # （移動方向に関係なく、アイテム自体がどの方向に並んでいるか）
    
    # 縦方向（上下）のチェック
    items_up = count_items_from_coord(item_coord, :up)
    items_down = count_items_from_coord(item_coord, :down)
    vertical_line = 1 + items_up + items_down
    
    if vertical_line >= 3 && items_up > 0 && items_down > 0
      # 縦に3つ以上並んでいて、両側にアイテムがある = 中央
      return true
    end
    
    # 横方向（左右）のチェック
    items_left = count_items_from_coord(item_coord, :left)
    items_right = count_items_from_coord(item_coord, :right)
    horizontal_line = 1 + items_left + items_right
    
    if horizontal_line >= 3 && items_left > 0 && items_right > 0
      # 横に3つ以上並んでいて、両側にアイテムがある = 中央
      return true
    end

    false
  end



  # 指定座標から指定方向に連続するアイテム数をカウント（世界マップから）
  def count_items_from_coord(start_coord, direction)
    return 0 unless start_coord && direction

    delta = DIRECTION_DELTAS[direction]
    return 0 unless delta

    count = 0
    current = start_coord

    10.times do
      next_coord = [current[0] + delta[0], current[1] + delta[1]]
      tile = @world[coord_key(next_coord)]
      break unless tile == TILE_ITEM

      count += 1
      current = next_coord
    end

    count
  end

  # 指定方向のアイテムを取得した場合、他の隣接アイテムがトラップになるか判定
  def would_create_trap_for_other_items?(target_dir, all_item_dirs, grid)
    return false if all_item_dirs.size <= 1

    # アイテム取得後、現在位置にブロックができる
    current_pos = @position

    # 他のアイテムの方向をチェック
    other_item_dirs = all_item_dirs.reject { |dir| dir == target_dir }

    other_item_dirs.any? do |other_dir|
      other_item_coord = coordinate_in_direction(other_dir)
      next false unless other_item_coord

      # アイテム取得後の状況をシミュレート
      # 現在位置にブロックができる
      blocked_count = count_blocked_neighbors_after_item_pickup(other_item_coord, current_pos, grid)

      # 3方向以上がブロックされていたらトラップ
      blocked_count >= 3
    end
  end

  # アイテム取得後（現在位置にブロックができた後）の、指定座標の周囲のブロック数をカウント
  def count_blocked_neighbors_after_item_pickup(coord, new_block_pos, grid)
    return 0 unless coord

    count = 0
    DIRECTION_DELTAS.each_value do |dx, dy|
      neighbor = [coord[0] + dx, coord[1] + dy]

      # 新しくできるブロックの位置か
      if neighbor == new_block_pos
        count += 1
        next
      end

      # 既存のブロックか
      if known_blocked?(neighbor)
        count += 1
        next
      end

      # グリッドから見えるブロックか
      if grid
        offset = [neighbor[0] - @position[0], neighbor[1] - @position[1]]
        index = OFFSET_TO_INDEX[offset]
        if index && (grid[index] == TILE_BLOCK || grid[index] == TILE_CHARACTER)
          count += 1
          next
        end
      end
    end

    count
  end

  def direction_score(dir, grid, diagonal_positions = nil)
    front_index = DIRECTIONS[dir][:index]
    score = 0.0

    case grid[front_index]
    when TILE_EMPTY
      score += 1.0
    when TILE_ITEM
      score += 5.0
    when TILE_BLOCK
      score -= 4.0
    when TILE_CHARACTER
      score -= 6.0
    end

    neighbors_for(dir).each do |idx|
      case grid[idx]
      when TILE_EMPTY
        score += 0.5
      when TILE_ITEM
        score += 2.0
      when TILE_BLOCK
        score -= 0.5
      when TILE_CHARACTER
        score -= 1.0
      end
    end

    coord = coordinate_in_direction(dir)
    if coord
      score += 0.8 if @world[coord_key(coord)].nil?  # 未探索ボーナスを増加
      score -= @visit_counts[coord] * 0.6  # 訪問ペナルティを増加 (0.4 → 0.6)
      diagonal_positions ||= diagonal_enemy_positions(grid)
      delta = diagonal_distance_delta(@position, coord, diagonal_positions)
      score += delta * 0.6 if delta
    end

    score += 0.3 if dir == @last_direction  # 直進ボーナスを減少 (0.5 → 0.3)
    score
  end

  def neighbors_for(dir)
    case dir
    when :up
      [1, 3, 4, 6]
    when :down
      [7, 9, 4, 6]
    when :left
      [1, 7, 2, 8]
    when :right
      [3, 9, 2, 8]
    else
      []
    end
  end

  def opposite_of(dir)
    case dir
    when :up then :down
    when :down then :up
    when :left then :right
    when :right then :left
    end
  end

  def adjacency_priority(dir)
    case dir
    when :up then 0
    when :right then 1
    when :down then 2
    when :left then 3
    else 4
    end
  end

  def determine_role(grid)
    enemy_visible = DIRECTIONS.any? { |_, meta| grid[meta[:index]] == TILE_CHARACTER }
    @role = enemy_visible ? :defense : :offense
  end

  def coord_key(coord)
    return nil unless coord
    "#{coord[0]},#{coord[1]}"
  end

  def parse_coord_key(key)
    return nil unless key
    parts = key.split(',', 2)
    return nil unless parts.size == 2
    [parts[0].to_i, parts[1].to_i]
  end

  def coordinate_from(coord, direction)
    delta = DIRECTION_DELTAS[direction]
    return nil unless coord && delta
    [coord[0] + delta[0], coord[1] + delta[1]]
  end

  def free_neighbor_count(position, blocked_dirs = [])
    blocked_coords = blocked_dirs.map { |dir| coordinate_from(position, dir) }.compact
    DIRECTIONS.keys.count do |dir|
      coord = coordinate_from(position, dir)
      next false unless coord
      next false if blocked_coords.include?(coord)

      key = coord_key(coord)
      status = trap_status(coord)
      next false if [:confirmed_trap, :pending_search, :suspected_trap].include?(status)
      next false if trap_tile?(coord)

      tile = @world[key]
      next false if tile == TILE_BLOCK || tile == TILE_CHARACTER

      true
    end
  end

  def known_blocked?(coord)
    return false unless coord

    status = trap_status(coord)
    return true if [:confirmed_trap, :pending_search, :suspected_trap].include?(status)
    return true if trap_tile?(coord)

    tile = @world[coord_key(coord)]
    tile == TILE_BLOCK || tile == TILE_CHARACTER
  end

  def known_dead_end?(coord, coming_from_dir)
    return false unless coord

    DIRECTIONS.keys.reject { |dir| dir == coming_from_dir }.all? do |dir|
      neighbor = coordinate_from(coord, dir)
      next false unless neighbor

      known_blocked?(neighbor)
    end
  end

  def mark_walled_item_traps_from_map
    @world.each do |key, tile|
      next unless tile == TILE_ITEM

      coord = parse_coord_key(key)
      next unless coord

      blocked_neighbors = DIRECTION_DELTAS.values.count do |dx, dy|
        neighbor = [coord[0] + dx, coord[1] + dy]
        known_blocked?(neighbor)
      end

      next unless blocked_neighbors >= 3

      mark_trap(coord, reason: :map_walled_item, status: :confirmed_trap)
    end
  end

  def blocked_by_trap_or_wall?(grid, direction)
    return false unless grid

    index = DIRECTIONS[direction][:index]
    tile = grid[index]
    coord = coordinate_in_direction(direction)
    status = coord ? trap_status(coord) : nil

    return true if tile == TILE_BLOCK
    # 安全確定されたマスはブロック扱いしない
    return false if status == :confirmed_safe
    return true if [:confirmed_trap, :pending_search, :suspected_trap].include?(status)
    return true if coord && trap_tile?(coord)

    false
  end

  # 完全に塞がれているか判定（厳格版）
  # suspected_trapやpending_searchは考慮せず、confirmed_trapのみをブロック扱い
  # これにより、まだ確定していないトラップで誤って「囲まれている」と判定することを防ぐ
  def blocked_by_confirmed_trap_or_wall?(grid, direction)
    return false unless grid

    index = DIRECTIONS[direction][:index]
    tile = grid[index]
    coord = coordinate_in_direction(direction)
    status = coord ? trap_status(coord) : nil

    # ブロックまたはキャラクターは確実にブロック
    return true if tile == TILE_BLOCK || tile == TILE_CHARACTER
    # 安全確定されたマスはブロック扱いしない
    return false if status == :confirmed_safe
    # confirmed_trapのみをブロック扱い（suspected_trap, pending_searchは含めない）
    return true if status == :confirmed_trap
    return true if coord && trap_tile?(coord)

    false
  end

  def surrounded_by_traps_or_walls?(grid)
    # 厳格版を使用：confirmed_trapのみを考慮
    DIRECTIONS.keys.all? { |dir| blocked_by_confirmed_trap_or_wall?(grid, dir) }
  end

  def safe_escape_directions(grid, enemy_dirs)
    # 敵の方向へ移動するのは危険なので、enemy_dirs 自体を unsafe とする
    unsafe = enemy_dirs
    DIRECTIONS.keys.reject do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      coord = coordinate_in_direction(dir)
      status = coord ? trap_status(coord) : nil
      # 安全確定されたマスは除外しない
      next false if status == :confirmed_safe
      tile == TILE_BLOCK || tile == TILE_CHARACTER ||
        unsafe.include?(dir) ||
        [:confirmed_trap, :pending_search, :suspected_trap].include?(status) ||
        (coord && trap_tile?(coord)) ||
        trapkaihi_suspected?(grid, dir)
    end
  end

  # ブロック設置が安全かチェックする。自分を完全に閉じ込めないことを確認。
  # grid の状態も考慮して、現在見えているブロックも反映する。
  def safe_to_block?(direction, grid = nil)
    coord = coordinate_in_direction(direction)
    return false unless coord

    # 現在の grid の状態を考慮して、自由な隣接マス数を計算
    free_count = count_free_neighbors_from_grid(grid) if grid
    free_count ||= free_neighbor_count(@position, [direction])
    
    return false if free_count < 2

    # ブロックを置いた後の状態をシミュレート
    world_copy = @world.dup
    world_copy[coord_key(coord)] = TILE_BLOCK
    accessible_space_size(world_copy, @position) > 2
  end

  # grid から見える範囲で、現在位置の自由な隣接マス数をカウントする。
  def count_free_neighbors_from_grid(grid)
    return nil unless grid
    
    DIRECTIONS.keys.count do |dir|
      index = DIRECTIONS[dir][:index]
      tile = grid[index]
      coord = coordinate_in_direction(dir)
      status = coord ? trap_status(coord) : nil
      next false if [:confirmed_trap, :pending_search, :suspected_trap].include?(status)
      next false if coord && trap_tile?(coord)

      tile == TILE_EMPTY || tile == TILE_ITEM
    end
  end

  # ブロックを置いた後の状態で escape 可能かチェックする。
  # ブロック設置と回避の競合を防ぐため、ブロックを置いても最低1方向に escape できることを確認。
  def would_escape_after_block?(grid, block_dir, enemy_dirs)
    coord = coordinate_in_direction(block_dir)
    return true unless coord  # 座標が取得できない場合は問題なしとみなす

    # ブロックを置いた後の grid をシミュレート
    simulated_grid = grid.dup
    simulated_grid[DIRECTIONS[block_dir][:index]] = TILE_BLOCK

    # ブロックを置いた後の状態で escape 可能な方向があるかチェック
    # 敵の方向、ブロック、キャラクター、トラップを避ける
    safe_dirs_after = DIRECTIONS.keys.reject do |dir|
      tile = simulated_grid[DIRECTIONS[dir][:index]]
      coord_after = coordinate_in_direction(dir)
      tile == TILE_BLOCK || tile == TILE_CHARACTER ||
        enemy_dirs.include?(dir) ||
        (coord_after && trap_tile?(coord_after)) ||
        would_trap_on_move?(dir, simulated_grid)
    end

    # 少なくとも2方向に escape 可能である必要がある（安全マージン）
    # 1方向だけでは、その方向が塞がれた場合に escape 不能になるため
    free_neighbors_after = safe_dirs_after.size
    free_neighbors_after >= 2
  end

  def accessible_space_size(world_map, start_pos)
    visited = {}
    queue = [start_pos]

    until queue.empty?
      current = queue.shift
      next if visited[current]

      visited[current] = true
      return visited.size if visited.size > 12

      DIRECTION_DELTAS.each do |_, (dx, dy)|
        next_pos = [current[0] + dx, current[1] + dy]
        tile = world_map[coord_key(next_pos)]
        status = trap_status(next_pos)
        next if tile == TILE_BLOCK || tile == TILE_CHARACTER
        next if [:confirmed_trap, :pending_search, :suspected_trap].include?(status)
        next if trap_tile?(next_pos)
        queue << next_pos
      end
    end

    visited.size
  end

  # メモ化版: 計算結果をキャッシュ
  def memoized_space_size(world_map, start_pos)
    @space_cache ||= {}
    cache_key = [start_pos, @turn_count]
    
    # 同一ターン内のみキャッシュ有効（ターンが変わるとクリア）
    if @space_cache[:turn] != @turn_count
      @space_cache = { turn: @turn_count }
    end
    
    @space_cache[cache_key] ||= accessible_space_size(world_map, start_pos)
  end

  def would_trap_on_move?(direction, grid = nil)
    return false unless direction

    grid ||= @last_grid
    next_coord = coordinate_in_direction(direction)
    return false unless next_coord

    # 安全確認を追加
    return true unless safe_position_against_enemies?(next_coord, grid)

    status = trap_status(next_coord)
    blocking_statuses = [:confirmed_trap, :pending_search, :suspected_trap]
    return true if blocking_statuses.include?(status)
    return true if trap_tile?(next_coord)

    # 確実に安全とマークされている場合は罠判定をスキップ
    return false if status == :confirmed_safe

    if grid && trapkaihi_walled_item?(grid, direction)
      return true unless status == :confirmed_safe
    end

    if grid && trapkaihi_suspected?(grid, direction) && status != :confirmed_safe
      return true
    end

    if grid && trapkaihi_trap_candidate?(grid, direction)
      return true
    end

    opposite = opposite_of(direction)
    return true if known_dead_end?(next_coord, opposite)

    # L字型の罠（2マス以下の狭い空間）を検出
    # 移動先から到達可能なスペースが2マス以下の場合は罠とみなす
    space_size = accessible_space_size(@world, next_coord)
    return true if space_size <= 2

    free_neighbor_count(next_coord, [opposite]) == 0
  end

  def losing_position?(grid, enemy_dirs)
    # 逃走判定を少し緩め、隣接自由数が 0 のときのみ真とする
    return true if free_neighbor_count(@position) <= 0
    return false if enemy_dirs.empty?
    safe_escape_directions(grid, enemy_dirs).empty?
  end

  # ブロック設置と escape の両方ができない場合のフォールバック行動。
  # 無限ループを防ぐため、トラップ判定を緩めてでも移動を試みるか、search を実行する。
  def force_escape_or_search(grid, enemy_dirs)
    # まず、トラップ判定を緩めた escape を試みる
    safe_dirs = DIRECTIONS.keys.reject do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      coord = coordinate_in_direction(dir)
      status = coord ? trap_status(coord) : nil
      
      # 安全確認を追加
      unsafe = coord && !safe_position_against_enemies?(coord, grid)

      tile == TILE_BLOCK || tile == TILE_CHARACTER ||
        enemy_dirs.include?(dir) ||
        [:confirmed_trap, :pending_search, :suspected_trap].include?(status) ||
        (coord && trap_tile?(coord)) ||
        trapkaihi_suspected?(grid, dir) || unsafe
    end
    
    # トラップ判定を緩めて移動可能な方向を探す
    if safe_dirs.any?
      # 最も安全そうな方向を選ぶ（訪問回数が少ない方向）
      chosen = safe_dirs.min_by do |dir|
        coord = coordinate_in_direction(dir)
        coord ? @visit_counts[coord] : Float::INFINITY
      end
      return action(:walk, chosen) if chosen
    end
    
    # 移動できない場合は search を実行（無限ループ防止）
    search_dir = enemy_dirs.first || @last_direction || :up
    action(:search, search_dir)
  end

  # 同じ行動が繰り返される場合、強制的に別の行動を選択する（無限ループ防止）。
  def force_alternative_action(grid, current_decision)
    return current_decision unless current_decision
    
    # 現在の行動と異なる行動を選択
    case current_decision[:verb]
    when :put
      # ブロック設置から walk や search に変更
      walkable = DIRECTIONS.keys.select do |dir|
        tile = grid[DIRECTIONS[dir][:index]]
        coord = coordinate_in_direction(dir)
        safe = coord.nil? || safe_position_against_enemies?(coord, grid)
        (tile == TILE_EMPTY || tile == TILE_ITEM) && safe
      end
      return action(:walk, walkable.first) if walkable.any?
      
      search_dir = @last_direction || :up
      return action(:search, search_dir)
    when :walk
      # 別の方向への walk を優先する（search は最終手段）
      current_dir = current_decision[:direction]
      alternative_dirs = DIRECTIONS.keys.reject { |dir| dir == current_dir }
      
      walkable = alternative_dirs.select do |dir|
        tile = grid[DIRECTIONS[dir][:index]]
        coord = coordinate_in_direction(dir)
        status = coord ? trap_status(coord) : nil
        
        # 敵隣接チェックを追加
        safe = coord.nil? || safe_position_against_enemies?(coord, grid)
        
        (tile == TILE_EMPTY || tile == TILE_ITEM) &&
          ![:confirmed_trap, :pending_search, :suspected_trap].include?(status) &&
          !(coord && trap_tile?(coord)) && safe
      end
      
      if walkable.any?
        # 訪問回数が少ない方向を優先
        chosen = walkable.min_by do |dir|
          coord = coordinate_in_direction(dir)
          coord ? @visit_counts[coord] : 0
        end
        return action(:walk, chosen)
      end
      
      # 移動できる方向がない場合のみ search を実行
      search_dir = @last_direction || :up
      return action(:search, search_dir)
    else
      # search から walk に変更
      walkable = DIRECTIONS.keys.select do |dir|
        tile = grid[DIRECTIONS[dir][:index]]
        coord = coordinate_in_direction(dir)
        safe = coord.nil? || safe_position_against_enemies?(coord, grid)
        (tile == TILE_EMPTY || tile == TILE_ITEM) && safe
      end
      return action(:walk, walkable.first) if walkable.any?
    end
    
    # フォールバック: 現在の行動を返す（何もできない場合）
    current_decision
  end
end
