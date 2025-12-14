class SmartChaser
  def choose_block_direction(enemy_dirs, grid)
    enemy_dirs
      .sort_by { |dir| adjacency_priority(dir) }
      .find do |dir|
        next false if block_history_limit_reached?(dir)
        grid[DIRECTIONS[dir][:index]] == TILE_CHARACTER &&
          !self_trap_if_put?(grid, dir) &&
          safe_to_block?(dir, grid)
      end
  end

  # 敵の真正面（隣接マス）への移動を防ぐための安全確認
  # ヒートマップの確率が比較的高い場所も回避する
  def safe_position_against_enemies?(target_coord, grid)
    return false unless target_coord && grid

    # 現在のグリッド上の敵位置を取得
    enemy_positions = enemy_positions_from_grid(grid)

    # 敵が見えている場合の厳密チェック
    unless enemy_positions.empty?
      # ターゲット座標が、いずれかの敵位置と隣接している（マンハッタン距離=1）場合は危険
      if enemy_positions.any? { |pos| manhattan_distance(target_coord, pos) == 1 }
        return false
      end

      # 距離2以内も危険（敵が1手で隣接できる）
      if enemy_positions.any? { |pos| manhattan_distance(target_coord, pos) == 2 }
        # 他に安全な選択肢がある場合は避ける（厳密には呼び出し元で判断）
        # ここでは警告レベルとして記録のみ
      end
    end

    # ============================================================
    # ヒートマップ（確率）に基づくチェック
    # 確率が比較的高い場所は避ける
    # ============================================================

    # 移動先そのものの危険度（閾値: 20%）
    prob_self = get_enemy_probability(target_coord)
    if prob_self && prob_self > 0.20
      return false
    end

    # 移動先の隣接マスの危険度（閾値: 30%）
    # 隣接マスに敵がいると、次のターンでPutされるリスクがある
    # 高確率マスの1つ前（隣接）にも移動しないよう、1つ以上で危険とする
    DIRECTIONS.keys.each do |dir|
      neighbor = coordinate_from(target_coord, dir)
      next unless neighbor
      prob = get_enemy_probability(neighbor)
      # 30%以上の確率で敵がいる隣接マスが1つでもあれば危険
      if prob && prob > 0.30
        return false
      end
    end

    # 移動先の周囲の合計確率が高い場合も危険
    total_surrounding_prob = calculate_surrounding_enemy_probability(target_coord)
    if total_surrounding_prob > 0.5
      return false
    end

    true
  end

  # 指定座標の周囲の敵存在確率の合計を計算
  def calculate_surrounding_enemy_probability(coord)
    return 0.0 unless coord

    total = 0.0
    # 自分自身の確率
    prob_self = get_enemy_probability(coord)
    total += prob_self if prob_self

    # 隣接4方向
    DIRECTIONS.keys.each do |dir|
      neighbor = coordinate_from(coord, dir)
      next unless neighbor
      prob = get_enemy_probability(neighbor)
      total += prob if prob
    end

    total
  end

  # 敵の移動を制限するためのブロック配置方向を選択する
  # 敵を倒せなくても、敵の隣接マスにブロックを置くことで動きを封じる
  def choose_restrict_direction(enemy_dirs, grid)
    # 敵がいる方向に対して、その敵の隣接マス（自分の射程内）にブロックを置けるか探す
    enemy_dirs.each do |enemy_dir|
      enemy_coord = coordinate_in_direction(enemy_dir)
      next unless enemy_coord

      # 敵の周りの空きマスを探す
      DIRECTIONS.keys.each do |dir|
        # 自分の位置から見たブロック配置候補
        target_coord = coordinate_from(@position, dir)
        next unless target_coord

        # その候補が敵に隣接しているか確認
        next unless manhattan_distance(target_coord, enemy_coord) == 1

        # ブロック配置可能かチェック
        if can_put_block_there?(grid, dir) && safe_to_block?(dir, grid)
           # 敵の逃げ道を塞ぐ効果が高いか簡易評価（オプション）
           return dir
        end
      end
    end
    nil
  end

  # escape 方向を選択する。スコアリングベースで最適な方向を選ぶ。
  # 理由: 単に前回の方向を優先するだけでは、安全で効率的な escape ができない。
  # 空きマス数、訪問回数、敵からの距離を総合的に評価することで、より良い方向を選択できる。
  def choose_escape_direction(grid, enemy_dirs)
    safe_dirs = safe_escape_directions(grid, enemy_dirs)
    # 安全確認: 敵に隣接するマスへの移動を除外
    safe_dirs.select! do |dir|
      coord = coordinate_in_direction(dir)
      safe_position_against_enemies?(coord, grid)
    end

    # デバッグ出力: 敵方向と安全候補を出して何を判断したか確認できるようにする
    # STDERR.puts "[debug] enemy_dirs=#{enemy_dirs.inspect} safe_dirs=#{safe_dirs.inspect} grid=#{grid.inspect}"
    return nil if safe_dirs.empty?

    # スコアリングベースで最適な方向を選択
    safe_dirs
      .map { |dir| [escape_direction_score(dir, grid, enemy_dirs), dir] }
      .max_by { |score, _dir| score }
      &.last
  end

  # choose_kill_direction は attack_strategy.rb の evaluate_attack_opportunity に統合されたため削除

  # escape 方向のスコアを計算する。空きマス数、訪問回数、敵からの距離、移動可能エリアの広さを考慮。
  # 動的重み付け対応
  def escape_direction_score(dir, grid, enemy_dirs)
    base = direction_score(dir, grid)
    coord = coordinate_in_direction(dir)
    
    return -Float::INFINITY unless coord

    # 動的重み取得（戦略に応じて変化）
    weights = dynamic_escape_weights(enemy_dirs)

    # 空きマス数が多い方向を優先（自由度が高い）
    free_spaces = free_neighbor_count(coord)
    free_bonus = free_spaces * weights[:freedom]
    
    # 移動可能エリアの広さを評価（袋小路を避ける）
    area_size = memoized_space_size(@world, coord)
    area_bonus = area_size * weights[:area]
    
    # 訪問回数が少ない方向を優先（新しいエリアへの移動）
    visit_penalty = @visit_counts[coord] * weights[:visit_penalty]
    
    # 敵から離れる方向を優先（敵方向と逆の方向にボーナス）
    enemy_distance_bonus = calculate_enemy_distance_bonus(dir, enemy_dirs) * weights[:enemy_distance]
    
    # 最近使った方向は少しペナルティ（多様性を保つ）
    recent_penalty = (@recent_moves.last(4).count(dir) || 0) * 0.2
    
    base + free_bonus + area_bonus - visit_penalty + enemy_distance_bonus - recent_penalty
  end

  # 動的重み計算（訪問ペナルティを増加して再訪問を抑制）
  # area（広さ）の重みを強化して広い空間への逃走を優先
  def dynamic_escape_weights(enemy_dirs)
    urgency = enemy_dirs.size / 4.0

    case @current_strategy
    when :defensive
      { freedom: 1.2, area: 1.5, visit_penalty: 0.4, enemy_distance: 2.0 }  # area: 0.8 → 1.5
    when :aggressive
      { freedom: 0.6, area: 0.8, visit_penalty: 0.5, enemy_distance: 1.0 }  # area: 0.4 → 0.8
    when :item_focus
      { freedom: 0.8, area: 1.0, visit_penalty: 0.6, enemy_distance: 1.5 }  # area: 0.5 → 1.0
    else  # balanced
      { freedom: 0.8 * (1 + urgency), area: 1.0 * (1 + urgency), visit_penalty: 0.5, enemy_distance: 1.5 * (1 + urgency) }  # area: 0.5 → 1.0
    end
  end

  # 敵から離れる方向にボーナスを与える。敵方向の反対方向を優先する。
  def calculate_enemy_distance_bonus(dir, enemy_dirs)
    return 0.0 if enemy_dirs.empty?
    
    # 敵方向の反対方向を計算
    enemy_opposites = enemy_dirs.map { |ed| opposite_of(ed) }
    
    if enemy_opposites.include?(dir)
      1.5  # 敵の反対方向には大きなボーナス
    else
      0.0
    end
  end

  # 指定方向の敵がブロック設置で逃げられなくなるか判定する。
  def enemy_trappable?(grid, direction)
    enemy_coord = coordinate_in_direction(direction)
    return false unless enemy_coord

    # 敵が移動可能な隣接マス数をカウントし、ゼロなら撃破可能と判断
    remaining_routes = enemy_escape_route_count(grid, enemy_coord)
    remaining_routes.zero?
  end

  # 敵が移動可能な隣接マス数をカウントする。
  def enemy_escape_route_count(grid, enemy_coord)
    DIRECTIONS.keys.count do |dir|
      next_coord = coordinate_from(enemy_coord, dir)
      next false unless next_coord
      next false if next_coord == @position

      tile = tile_from_memory(grid, next_coord)
      walkable_for_enemy_tile?(tile)
    end
  end

  # グリッド情報とワールド情報を統合してタイル種別を取得する。
  def tile_from_memory(grid, coord)
    offset = [coord[0] - @position[0], coord[1] - @position[1]]
    index = OFFSET_TO_INDEX[offset]
    if index
      grid[index]
    else
      @world[coord_key(coord)]
    end
  end

  # 敵が移動可能とみなすタイルか判定する。
  def walkable_for_enemy_tile?(tile)
    tile.nil? || tile == TILE_EMPTY || tile == TILE_ITEM
  end

  def choose_exploration_direction(grid)
    # まず対称情報を考慮した探索方向を試す
    sym_dir = choose_symmetric_aware_exploration(grid) if respond_to?(:choose_symmetric_aware_exploration)
    return sym_dir if sym_dir && front_walkable?(grid, sym_dir) && !would_trap_on_move?(sym_dir, grid)
    
    candidates = DIRECTIONS.keys.reject do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      coord = coordinate_in_direction(dir)
      status = coord ? trap_status(coord) : nil
      
      # 安全確認を追加
      unsafe = coord && !safe_position_against_enemies?(coord, grid)
      
      # 境界外チェック
      out = coord && respond_to?(:out_of_bounds?) && out_of_bounds?(coord)

      tile == TILE_BLOCK || tile == TILE_CHARACTER ||
        [:confirmed_trap, :pending_search, :suspected_trap].include?(status) ||
        (coord && trap_tile?(coord)) || unsafe || out
    end
    return nil if candidates.empty?

    candidates
      .map do |dir|
        coord = coordinate_in_direction(dir)
        
        # 未探索エリアへのボーナス（対称推論を考慮）
        unknown_bonus = 0.0
        truly_unknown_bonus = 0.0
        if coord
          # 移動先の周囲に未探索エリアがあるかチェック
          neighbors_at(coord).each do |n|
            next if respond_to?(:out_of_bounds?) && out_of_bounds?(n)
            if @world[coord_key(n)].nil?
              unknown_bonus += 0.5
              # 真に未知（対称推論でも分からない）なら追加ボーナス
              truly_unknown_bonus += 0.5 if respond_to?(:is_truly_unknown?) && is_truly_unknown?(n)
            end
          end
          
          # 端付近へのペナルティ
          if respond_to?(:near_edge?) && near_edge?(coord)
            unknown_bonus -= 1.0
          end
        end

        penalty = (@recent_moves.last(6).count(dir) || 0) * 0.4  # 0.3 → 0.4
        [direction_score(dir, grid) + unknown_bonus + truly_unknown_bonus - penalty, dir]
      end
      .sort_by { |score, dir| [-score, adjacency_priority(dir)] }
      .dig(0, 1)
  end

  # 緊急退避：自由度が極端に低いときに、より安全な場所へ移動する
  def emergency_escape_direction(grid, enemy_dirs)
    candidates = DIRECTIONS.keys.reject do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      coord = coordinate_in_direction(dir)
      status = coord ? trap_status(coord) : nil
      
      # 安全確認を追加
      unsafe = coord && !safe_position_against_enemies?(coord, grid)

      tile == TILE_BLOCK || tile == TILE_CHARACTER || enemy_dirs.include?(dir) ||
        [:confirmed_trap, :pending_search, :suspected_trap].include?(status) ||
        (coord && trap_tile?(coord)) || unsafe
    end
    return nil if candidates.empty?

    candidates
      .map do |dir|
        coord = coordinate_in_direction(dir)
        safety = coord ? free_neighbor_count(coord) : 0
        visit_penalty = coord ? @visit_counts[coord] * 0.2 : 0
        recent_penalty = (@recent_moves.last(4).count(dir) || 0) * 0.1
        [safety - visit_penalty - recent_penalty, dir]
      end
      .max_by { |score, _dir| score }
      &.last
  end

  # 現在の視界情報から敵の座標を収集する（斜めも含む）
  def enemy_positions_from_grid(grid)
    return [] unless grid

    INDEX_TO_OFFSET.each_with_object([]) do |(index, (dx, dy)), acc|
      next if index == 5
      acc << [@position[0] + dx, @position[1] + dy] if grid[index] == TILE_CHARACTER
    end
  end

  def diagonal_threat_action(grid)
    return nil unless grid

    diagonal_indexes = DIAGONAL_INDEXES.select { |idx| grid[idx] == TILE_CHARACTER }
    return nil if diagonal_indexes.empty?

    diagonal_positions = diagonal_enemy_positions(grid, diagonal_indexes)

    diagonal_indexes.each do |diag_idx|
      block_action = diagonal_block_action_for(diag_idx, grid)
      if block_action
        @consecutive_block_attempts = [@consecutive_block_attempts + 1, 3].min
        return block_action
      end
    end

    diagonal_escape_action(diagonal_indexes, diagonal_positions, grid)
  end

  def diagonal_block_action_for(diagonal_index, grid)
    return nil if @consecutive_block_attempts >= 3

    candidates = DIAGONAL_BLOCK_CANDIDATES[diagonal_index] || []
    return nil if candidates.empty?

    enemy_dirs = candidates.select do |direction|
      grid[DIRECTIONS[direction][:index]] == TILE_CHARACTER
    end

    viable = candidates.filter_map do |direction|
      next if block_history_limit_reached?(direction)
      next unless can_put_block_there?(grid, direction)
      next unless safe_to_block?(direction, grid)
      next unless would_escape_after_block?(grid, direction, enemy_dirs)

      coord = coordinate_in_direction(direction)
      visit_penalty = coord ? @visit_counts[coord] * 0.2 : 0.0
      mobility = free_neighbor_count(@position, [direction])
      last_dir_bonus = @last_direction && opposite_of(@last_direction) == direction ? 0.4 : 0.0
      score = mobility - visit_penalty + last_dir_bonus
      
      { dir: direction, score: score }
    end

    return nil if viable.empty?

    target = viable.max_by { |entry| entry[:score] }
    action(:put, target[:dir])
  end

  def can_put_block_there?(grid, direction)
    index = DIRECTIONS[direction][:index]
    tile = grid[index]
    coord = coordinate_in_direction(direction)
    return false unless coord

    return false unless tile == TILE_EMPTY

    status = trap_status(coord)
    return false if [:confirmed_trap, :suspected_trap, :pending_search].include?(status)
    true
  end

  def diagonal_escape_action(diagonal_indexes, diagonal_positions, grid)
    escape_dirs = diagonal_indexes.flat_map { |idx| DIAGONAL_ESCAPE_OPTIONS[idx] }.uniq
    return nil if escape_dirs.empty?

    options = escape_dirs.filter_map do |direction|
      next unless front_walkable?(grid, direction)
      next if would_trap_on_move?(direction, grid)

      coord = coordinate_in_direction(direction)
      next if coord && trap_tile?(coord)

      # 安全確認を追加
      next if coord && !safe_position_against_enemies?(coord, grid)

      score = direction_score(direction, grid, diagonal_positions)
      score += 0.5 if @last_direction && direction != @last_direction
      delta = diagonal_distance_delta(@position, coord, diagonal_positions)
      score += delta * 0.8 if delta
      { dir: direction, score: score }
    end

    best = options.max_by { |entry| entry[:score] }
    best ? action(:walk, best[:dir]) : nil
  end

  def diagonal_enemy_positions(grid, indexes = DIAGONAL_INDEXES)
    return [] unless grid
    indexes.filter_map do |idx|
      next unless grid[idx] == TILE_CHARACTER
      offset = INDEX_TO_OFFSET[idx]
      [@position[0] + offset[0], @position[1] + offset[1]]
    end
  end

  def diagonal_distance_delta(from_pos, to_pos, diagonal_positions)
    return nil if diagonal_positions.nil? || diagonal_positions.empty?
    return nil if from_pos.nil? || to_pos.nil?

    current_distance = diagonal_positions.map { |pos| manhattan_distance(from_pos, pos) }.min
    future_distance = diagonal_positions.map { |pos| manhattan_distance(to_pos, pos) }.min
    return nil if current_distance.nil? || future_distance.nil?

    future_distance - current_distance
  end

end
