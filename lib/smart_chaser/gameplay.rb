class SmartChaser
  def initialize(name = 'foolish_bot')
    @client = CHaserConnect.new(name)
    @position = [0, 0]
    @world = { coord_key(@position) => TILE_EMPTY }
    @visit_counts = Hash.new(0)
    @visit_counts[@position] = 1
    @turn_count = 0
    @move_count = 0
    @last_direction = nil
    @last_turn_scan = nil
    @recent_visions = []
    @recent_moves = []
    @stuck_counter = 0
    @block_memory = Hash.new { |h, k| h[k] = Set.new }
    @role = :unknown
    @last_position = @position.dup
    @position_unchanged_count = 0
    @consecutive_block_attempts = 0
    @last_action = nil
    @same_action_count = 0
    @trap_tiles = Set.new
    @last_grid = nil
    @trap_checks = {}
    @search_cache = {}  # search結果のキャッシュ（貫通判定）
    @map_renderer = nil
    @gui_error = false
    @current_strategy = :balanced
    @historical_items = Set.new # 取得済みアイテム等の位置を記憶（対称推論用）
    @self_placed_blocks = Set.new # 自分で置いたブロック（対称推論から除外）
    @last_attack_turn = nil # ヒステリシス用: 最後に攻撃を行ったターン

    # 目標コミットメント機構: 目標のフラッピングを防止
    @current_target = nil           # 現在の目標座標
    @target_type = nil              # 目標タイプ (:item, :frontier, :exploration)
    @target_commit_turns = 0        # 目標にコミットしたターン数
    @target_max_commit = 8          # 最大コミットターン数

    # アイテム巡回最適化用
    @planned_item_route = []        # 計画されたアイテム巡回ルート
    @last_target = nil              # 直前のターゲット（ヒステリシス用）

    init_enemy_tracker
    init_decision_logger
    init_localizer

    # 位置特定時のコールバック登録
    if @localizer
      @localizer.set_on_localized do
        retroactive_symmetry_update
        fill_boundary_walls
      end
    end

    start_gui_if_available
  end

  def play
    loop do
      vision = @client.getReady
      break unless continue?(vision)

      grid = normalize_grid(vision)
      @last_grid = grid if grid
      @turn_count += 1

      update_world_state(grid)
      update_enemy_tracking(grid)
      update_localizer_with_grid(grid)
      
      remaining = estimate_remaining_turns
      determine_strategy_mode(remaining)
      
      render_world_map(@move_count * 2 + 1)
      push_recent_vision(grid)
      determine_role(grid) if @role == :unknown
      
      if @position == @last_position
        @position_unchanged_count += 1
      else
        @position_unchanged_count = 0
        @last_position = @position.dup
      end
      
      stuck = stuck_here? || @position_unchanged_count >= 3

      decision = decide_action(grid, stuck)
      
      if decision && decision[:lockdown]
        @same_action_count = 0
      elsif decision && decision[:item_pickup]
        # アイテム取得時は同じ方向への移動を許可（直線上のアイテムを連続取得）
        @same_action_count = 0
      elsif decision == @last_action
        @same_action_count += 1
        if @same_action_count >= 3
          decision = force_alternative_action(grid, decision)
          @same_action_count = 0
        end
      else
        @same_action_count = 0
      end
      
      @last_action = decision
      
      result = execute(decision)
      remember(decision, result)
      @move_count += 1
      render_world_map(@move_count * 2)
    end
  ensure
    @client.close
    wait_for_gui_close_if_needed
  end

  private

  def continue?(vision)
    vision && vision[0] == 1
  end

  def decide_action(grid, stuck = false)
    @turn_start_time = Time.now
    
    update_enemy_tracking(grid)
    enemy_dirs = DIRECTIONS.keys.select { |dir| grid[DIRECTIONS[dir][:index]] == TILE_CHARACTER }
    enemy_positions = enemy_positions_from_grid(grid)
    heart_dirs = DIRECTIONS.keys.select { |dir| grid[DIRECTIONS[dir][:index]] == TILE_ITEM }

    start_decision_tree(
      enemy_count: enemy_positions.size,
      item_count: heart_dirs.size,
      strategy: @current_strategy,
      freedom: free_neighbor_count(@position)
    )

    check_timeout = -> {
      if Time.now - @turn_start_time > 0.4
        fallback = action(:walk, DIRECTIONS.keys.sample)
        select_decision(fallback, "タイムアウト回避のための緊急行動")
        return fallback
      end
      nil
    }

    if surrounded_by_traps_or_walls?(grid)
      add_decision_branch("閉じ込め判定", true, nil)
      search_dir = choose_search_direction(enemy_dirs)
      lockdown_action = action(:search, search_dir)
      lockdown_action[:lockdown] = true
      select_decision(lockdown_action, "周囲をブロック/トラップで囲まれているため探索")
      return lockdown_action
    end

    # タイムアウトチェック
    if (timeout_action = check_timeout.call); return timeout_action; end

    # 敵が隣接している場合
    if enemy_dirs.any?
      add_decision_branch("敵隣接", true, nil)

      # 敵が目の前（上下左右）にいる場合は必ずブロックを置く（即勝利）
      enemy_dirs.each do |dir|
        if grid[DIRECTIONS[dir][:index]] == TILE_CHARACTER
          result = action(:put, dir)
          select_decision(result, "敵の上にブロック設置で即勝利")
          return result
        end
      end

      # 敵が目の前にいない場合は逃走
      # 緊急退避：自由度が極端に低い場合
      if free_neighbor_count(@position) <= 1
        emergency_dir = emergency_escape_direction(grid, enemy_dirs)
        if emergency_dir
          result = action(:walk, emergency_dir)
          select_decision(result, "自由度極低のため緊急退避")
          return result
        end
      end

      # 敵から距離を取る方向を選択
      retreat_dir = best_retreat_direction(grid, enemy_positions)
      if retreat_dir
        result = action(:walk, retreat_dir)
        select_decision(result, "敵から逃走")
        return result
      end

      # タイムアウトチェック
      if (timeout_action = check_timeout.call); return timeout_action; end

      # 安全な逃走方向を選択
      escape_dir = choose_escape_direction(grid, enemy_dirs)
      if escape_dir
        result = action(:walk, escape_dir)
        select_decision(result, "敵から離脱")
        return result
      end

      # 逃げ道が無い場合は緊急回避手段を使用
      result = force_escape_or_search(grid, enemy_dirs)
      select_decision(result, "逃げ道なし、緊急回避")
      return result
    elsif enemy_positions.any?
      add_decision_branch("敵斜め位置・逃走優先", true, nil)
      
      # タイムアウトチェック
      if (timeout_action = check_timeout.call); return timeout_action; end

      # 斜め位置の敵からも逃走優先
      retreat_dir = best_retreat_direction(grid, enemy_positions)
      if retreat_dir
        result = action(:walk, retreat_dir)
        select_decision(result, "斜め敵から逃走")
        return result
      end
    else
      add_decision_branch("敵なし", true, nil)
    end

    # タイムアウトチェック
    if (timeout_action = check_timeout.call); return timeout_action; end

    # アイテム収集（A*探索使用）
    unless heart_dirs.empty?
      add_decision_branch("隣接アイテム", true, nil, heart_dirs.size)
      heart_dirs.reject! do |dir|
        coord = coordinate_in_direction(dir)
        status = coord ? trap_status(coord) : nil
        status == :confirmed_trap
      end

      # 複数アイテムがある場合、トラップを作らない方向を優先
      target_dir = choose_best_adjacent_item_direction(heart_dirs, grid)

      if target_dir
        if (search_action = maybe_trap_search_before_move(target_dir, grid))
          select_decision(search_action, "アイテム前の罠確認")
          return search_action
        end
        trap_check = would_trap_on_move?(target_dir, grid)
        unless trap_check
          result = action(:walk, target_dir)
          result[:item_pickup] = true  # アイテム取得フラグを設定
          select_decision(result, "隣接アイテムを取得")
          return result
        end
      end
    end

    # タイムアウトチェック
    if (timeout_action = check_timeout.call); return timeout_action; end

    # ============================================================
    # アイテム収集（A*探索）
    # ============================================================
    best_item = best_item_target
    if best_item
      item_distance = best_item[:distance]

      # 探索すべきか判定（未探索率20%以上かつ距離12以上なら探索優先）
      if should_explore_instead_of_item?(item_distance, 0)
        add_decision_branch("探索優先", true, nil)
        # 探索を優先（後のフロンティア探索へ）
      else
        add_decision_branch("アイテム発見", true, nil, best_item[:efficiency])

        # A*でアイテムへ移動
        astar_item_dir = astar_first_step(->(pos) { pos == best_item[:coord] }, enemy_positions, avoid_items: best_item[:avoid_middle])
        if astar_item_dir && front_walkable?(grid, astar_item_dir) && !would_trap_on_move?(astar_item_dir, grid)
          # 敵隣接マスへの移動を禁止
          coord = coordinate_in_direction(astar_item_dir)
          if coord && safe_position_against_enemies?(coord, grid)
            if (search_action = maybe_trap_search_before_move(astar_item_dir, grid))
              select_decision(search_action, "A*経路上の罠確認")
              return search_action
            end
            result = action(:walk, astar_item_dir)
            select_decision(result, "A*探索でアイテムへ移動（効率: #{format('%.2f', best_item[:efficiency])}）")
            return result
          end
        end
      end
    end

    # タイムアウトチェック
    if (timeout_action = check_timeout.call); return timeout_action; end

    # A*探索のみを使用（コスト付き探索は削除）

    # 未探索エリアへ移動
    frontier_info = best_frontier_by_priority if respond_to?(:best_frontier_by_priority)
    if frontier_info
      # フロンティアを目標として設定
      set_target(frontier_info[:from], :frontier)
    end

    step_to_frontier = astar_to_frontier(enemy_positions) || next_step_to_frontier
    if step_to_frontier
      add_decision_branch("未探索エリア", true, nil)
      if (search_action = maybe_trap_search_before_move(step_to_frontier, grid))
        select_decision(search_action, "未探索エリア前の罠確認")
        return search_action
      end
      if front_walkable?(grid, step_to_frontier) && !would_trap_on_move?(step_to_frontier, grid)
        # 敵隣接マスへの移動を禁止
        coord = coordinate_in_direction(step_to_frontier)
        if coord && safe_position_against_enemies?(coord, grid)
          result = action(:walk, step_to_frontier)
          select_decision(result, "未探索エリアへ探索")
          return result
        end
      end
    end

    exploration_dir = choose_exploration_direction(grid)

    if stuck && exploration_dir
      alt = break_stuck_choice(grid)
      if alt
        result = action(:walk, alt)
        select_decision(result, "スタック解消のため別方向へ")
        return result
      end
    end
    if exploration_dir
      if (search_action = maybe_trap_search_before_move(exploration_dir, grid))
        select_decision(search_action, "探索前の罠確認")
        return search_action
      end
      unless would_trap_on_move?(exploration_dir, grid)
        result = action(:walk, exploration_dir)
        select_decision(result, "探索方向へ移動")
        return result
      end
    end

    # 位置特定のためのSearch（後半で暇なとき）
    if should_use_search_for_localization?(grid)
      loc_search_dir = get_best_search_direction_for_localization
      if loc_search_dir
        result = action(:search, loc_search_dir)
        select_decision(result, "位置特定のため探索（候補: #{@localizer&.candidates_count}）")
        return result
      end
    end

    search_dir = choose_search_direction(enemy_dirs)
    result = action(:search, search_dir)
    select_decision(result, "移動先なし、周囲を探索")
    result
  end

  def execute(decision)
    direction = decision[:direction]
    verb = decision[:verb]
    command = DIRECTIONS.fetch(direction).fetch(verb)
    @client.public_send(command)
  end

  # 実行した行動の結果を記録し、ワールドマップと位置情報を更新する。
  def remember(decision, result)
    success = action_success?(result)
    @last_turn_scan = result

    case decision[:verb]
    when :walk
      if success
        # アイテムを取得したかチェック（移動先がアイテムだった場合）
        # アイテム取得時、現在位置（移動前）にブロックが生成されるため、それを自作ブロックとして記録
        target_pos = coordinate_in_direction(decision[:direction])
        if target_pos
          target_key = coord_key(target_pos)
          if @world[target_key] == TILE_ITEM
             @self_placed_blocks.add(coord_key(@position))
          end
        end

        apply_successful_walk(decision[:direction])
        @consecutive_block_attempts = 0  # 移動成功時はリセット
      end
    when :put
      if success
        register_block(decision[:direction])
        
        # 自分が置いたブロックを記録（対称推論から除外するため）
        placed_coord = coordinate_in_direction(decision[:direction])
        if placed_coord
           @self_placed_blocks.add(coord_key(placed_coord))
        end

        record_block_at_current_position(decision[:direction])
        @consecutive_block_attempts = 0  # ブロック設置成功時はリセット
      end
    when :search
      handle_search_result(decision[:direction], result) if success
    end

    return unless success

    grid_after_action =
      case decision[:verb]
      when :walk, :put
        normalize_grid(result)
      else
        nil
      end
    if grid_after_action
      @last_grid = grid_after_action
      update_world_state(grid_after_action)
    end
  end

  def action(verb, direction)
    { verb: verb, direction: direction }
  end

  def update_world_state(grid)
    return unless grid

    INDEX_TO_OFFSET.each do |index, offset|
      tile = grid[index]
      next if tile.nil?

      coord = [@position[0] + offset[0], @position[1] + offset[1]]
      key = coord_key(coord)
      
      # 新規タイルの場合のみ観測を記録
      record_tile_observation(tile) if @world[key].nil?
      
      @world[key] = tile
      
      # アイテム位置を履歴に保存（取得しても対称推論に使うため）
      if tile == TILE_ITEM
        @historical_items.add(key)
      end
      
      # ブロック・アイテム観測時は対称位置も推論
      # ただし、自分で置いたブロックは除外する（マップ生成時のものではないため）
      if tile == TILE_ITEM || (tile == TILE_BLOCK && !@self_placed_blocks.include?(key))
        apply_symmetric_inference(coord, tile)
      end

      # 空のブロックは確実に戻れるので罠ではない
      if tile == TILE_EMPTY
        mark_safe(coord, reason: :empty_block)
      end

      next unless TRAPKAIHI_INDEX_TO_DIAGONALS.key?(index)

      status = trap_status(coord)

      if trapkaihi_walled_item_for_index?(grid, index)
        # 空白マスは罠ではない（戻れるため）
        if (status.nil? || status == :suspected_trap) && tile != TILE_EMPTY
          mark_suspected_trap(coord, reason: :walled_item)
        end
      elsif trap_reason(coord) == :walled_item && status && status != :confirmed_trap
        mark_safe(coord, reason: :walled_item)
      end
    end

    mark_walled_item_traps_from_map
    
    # マップ境界推定を更新
    update_map_boundary_estimate
  end

  def trap_tile?(coord)
    return false unless coord
    key = coord_key(coord)
    @trap_tiles.include?(key)
  end

  def trap_status(coord)
    entry = @trap_checks[coord_key(coord)]
    entry && entry[:status]
  end

  def trap_reason(coord)
    entry = @trap_checks[coord_key(coord)]
    entry && entry[:reason]
  end

  def mark_trap(coord, reason: :search, status: :confirmed_trap)
    key = coord_key(coord)
    return unless key

    @trap_tiles << key
    entry = (@trap_checks[key] ||= {})
    entry[:status] = status
    entry[:reason] = reason
    entry[:updated_turn] = @turn_count
  end

  def mark_suspected_trap(coord, reason: :walled_item)
    key = coord_key(coord)
    return unless key

    entry = (@trap_checks[key] ||= {})
    entry[:status] = :suspected_trap
    entry[:reason] = reason
    entry[:updated_turn] = @turn_count
  end

  def mark_safe(coord, reason: :search)
    key = coord_key(coord)
    return unless key

    @trap_tiles.delete(key)
    entry = (@trap_checks[key] ||= {})
    entry[:status] = :confirmed_safe
    entry[:reason] = reason
    entry[:updated_turn] = @turn_count
  end

  def trapkaihi_walled_item_for_index?(grid, index)
    diag_indices = TRAPKAIHI_INDEX_TO_DIAGONALS[index]
    return false unless diag_indices && grid

    front_tile = grid[index]
    front_coord = grid_coord_for(index)
    front_is_item = front_tile == TILE_ITEM || (front_coord && @world[coord_key(front_coord)] == TILE_ITEM)
    return false unless front_is_item

    diag_indices.all? { |di| grid_blocked?(grid, di) }
  end

  def trapkaihi_walled_item?(grid, direction)
    return false unless grid

    diag_indices = TRAPKAIHI_DIAGONALS[direction]
    return false unless diag_indices

    front_index = DIRECTIONS[direction][:index]
    front_coord = grid_coord_for(front_index)
    front_tile = grid[front_index]
    front_is_item = front_tile == TILE_ITEM || (front_coord && @world[coord_key(front_coord)] == TILE_ITEM)
    return false unless front_is_item

    diag_indices.all? { |idx| grid_blocked?(grid, idx) }
  end

  def trapkaihi_suspected?(grid, direction)
    return false unless grid

    diag_indices = TRAPKAIHI_DIAGONALS[direction]
    return false unless diag_indices

    front_index = DIRECTIONS[direction][:index]
    front_coord = coordinate_in_direction(direction)
    return false unless front_coord

    front_status = trap_status(front_coord)
    return false if [:confirmed_trap, :pending_search, :suspected_trap].include?(front_status)
    return false if trap_tile?(front_coord)

    front_tile = grid[front_index]
    return false unless front_tile == TILE_EMPTY || front_tile == TILE_ITEM

    diagonal_blocked = diag_indices.all? { |idx| grid_blocked?(grid, idx) }
    return false unless diagonal_blocked
    return true if front_tile == TILE_ITEM

    return true if map_confirms_trap_ahead?(grid, front_coord, direction)

    false
  end

  def trapkaihi_trap_candidate?(grid, direction)
    coord = coordinate_in_direction(direction)
    return false unless coord

    status = trap_status(coord)
    return false if status == :confirmed_safe
    return true if status == :confirmed_trap

    return false unless grid
    return true if trapkaihi_walled_item?(grid, direction) && status != :confirmed_safe
    return false unless trapkaihi_suspected?(grid, direction)

    forward_coord = coordinate_from(coord, direction)
    forward_tile = tile_from_memory(grid, forward_coord)
    forward_tile == TILE_BLOCK || forward_tile == TILE_CHARACTER
  end

  def map_confirms_trap_ahead?(grid, front_coord, direction)
    return false unless front_coord

    status = trap_status(front_coord)
    return true if status == :confirmed_trap
    return false if status == :confirmed_safe

    return true if trap_tile?(front_coord)

    forward_coord = coordinate_from(front_coord, direction)
    return false unless forward_coord

    forward_status = trap_status(forward_coord)
    return true if forward_status == :confirmed_trap
    return false if forward_status == :confirmed_safe
    return true if trap_tile?(forward_coord)

    forward_tile = tile_from_memory(grid, forward_coord)
    return false if forward_tile.nil?

    !walkable_tile?(forward_tile)
  end

  def grid_coord_for(index)
    offset = INDEX_TO_OFFSET[index]
    return nil unless offset

    [@position[0] + offset[0], @position[1] + offset[1]]
  end

  def grid_blocked?(grid, index)
    return false unless grid

    tile = grid[index]
    return true if tile == TILE_BLOCK || tile == TILE_CHARACTER

    coord = grid_coord_for(index)
    coord && known_blocked?(coord)
  end

  def front_walkable?(grid, direction)
    return false unless direction

    index = DIRECTIONS[direction][:index]
    tile = grid[index]
    coord = coordinate_in_direction(direction)
    if coord
      status = trap_status(coord)

      # 空白マスはwalled_itemとしてマークしない（戻れるため安全）
      if trapkaihi_walled_item?(grid, direction) && status != :confirmed_safe && tile != TILE_EMPTY
        mark_suspected_trap(coord, reason: :walled_item)
        return false
      end

      return false if [:confirmed_trap, :suspected_trap, :pending_search].include?(status)
      return false if trap_tile?(coord)
      
      # 安全確認を追加
      return false unless safe_position_against_enemies?(coord, grid)
      
      # マップデータから行き止まり検知（サーチ不要）
      # 空白マスは行き止まりでも罠としてマークしない（戻れるため安全）
      if respond_to?(:is_dead_end?) && is_dead_end?(coord, 2) && tile != TILE_EMPTY
        mark_suspected_trap(coord, reason: :dead_end)
        return false
      end
    end

    tile && tile != TILE_BLOCK && tile != TILE_CHARACTER
  end

  # 罠チェックサーチ（アイテム移動時のみに限定）
  # サーチ削減: 空マスへの移動ではサーチを行わず、マップデータで判断する
  # キャッシュされたsearchデータを再利用してサーチをスキップ
  def maybe_trap_search_before_move(direction, grid)
    return nil unless direction && grid

    coord = coordinate_in_direction(direction)
    return nil unless coord

    # アイテムへの移動時のみサーチを行う（サーチ回数削減）
    front_index = DIRECTIONS[direction][:index]
    front_tile = grid[front_index]
    return nil unless front_tile == TILE_ITEM

    status = trap_status(coord)
    return nil if status == :confirmed_safe
    return nil if status == :confirmed_trap
    return nil if status == :pending_search

    suspected = trapkaihi_suspected?(grid, direction) || status == :suspected_trap
    return nil unless suspected

    # ============================================================
    # キャッシュチェック: 過去のsearchデータでこの座標が「貫通」していればスキップ
    # ============================================================
    if can_skip_search_using_cache?(coord, direction)
      mark_safe(coord)
      return nil
    end

    key = coord_key(coord)
    entry = (@trap_checks[key] ||= {})
    mark_suspected_trap(coord, reason: :walled_item) if trapkaihi_walled_item?(grid, direction) && status.nil?

    entry[:status] = :pending_search
    entry[:direction] = direction
    entry[:requested_turn] = @turn_count
    entry[:origin] = @position.dup

    action(:search, direction)
  end

  # 過去のsearchデータを使ってsearchをスキップできるかチェック
  # 同じ方向で、この座標が「貫通している」ことがキャッシュされていればtrue
  def can_skip_search_using_cache?(target_coord, direction)
    delta = DIRECTION_DELTAS[direction]
    return false unless delta

    # 9ターン以内のsearchデータをチェック
    @search_cache.each do |cache_key, cache_entry|
      next if @turn_count - cache_entry[:turn] > 9
      next unless cache_entry[:direction] == direction
      next unless cache_entry[:data].is_a?(Array)

      origin = cache_entry[:origin]
      next unless origin

      # このsearchデータがtarget_coordをカバーしているかチェック
      # originからdirection方向に進んだ位置にtarget_coordがあるか
      1.upto(9) do |dist|
        check_coord = [origin[0] + delta[0] * dist, origin[1] + delta[1] * dist]
        if check_coord == target_coord
          # target_coordはこのsearchでカバーされている
          # そこから先もさらにカバーされている（ブロックがなければ）
          # searchデータでこの位置以降が「貫通」しているか確認
          remaining_data = cache_entry[:data][dist..-1]
          if remaining_data && remaining_data.any?
            # 残りのデータで最低3マス先まで歩行可能 → 貫通と判定
            walkable_count = remaining_data.take(3).count { |t| walkable_tile?(t) }
            if walkable_count >= 3
              return true
            end
          end
          break
        end
      end
    end

    false
  end

  def handle_search_result(direction, result)
    return unless direction && result.is_a?(Array)

    update_search_result(direction, result)
    analyze_trap_search(direction, result)
  end

  def update_search_result(direction, result)
    delta = DIRECTION_DELTAS[direction]
    return unless delta
    return unless result.is_a?(Array)

    max_distance = [result.size - 1, 9].min
    1.upto(max_distance) do |distance|
      tile = result[distance]
      next if tile.nil? || tile == TILE_UNKNOWN

      coord = [@position[0] + delta[0] * distance, @position[1] + delta[1] * distance]
      @world[coord_key(coord)] = tile
    end

    mark_walled_item_traps_from_map
  end

  def analyze_trap_search(direction, result)
    delta = DIRECTION_DELTAS[direction]
    return unless delta
    return unless result.is_a?(Array)

    coord = coordinate_in_direction(direction)
    return unless coord

    key = coord_key(coord)
    entry = @trap_checks[key]
    # Skip automatic trap resolution unless the tile was previously flagged as suspicious.
    return unless entry && [:pending_search, :suspected_trap].include?(entry[:status])

    # ============================================================
    # searchの生データをキャッシュに保存（移動後も再利用可能）
    # ============================================================
    cache_key = "#{@turn_count}_#{@position.inspect}_#{direction}"
    @search_cache[cache_key] = {
      origin: @position.dup,
      direction: direction,
      data: result.dup,
      turn: @turn_count
    }
    # 古いキャッシュをクリーンアップ（10ターン以上前のもの）
    @search_cache.delete_if { |_, v| @turn_count - v[:turn] > 10 }

    max_distance = [result.size - 1, 9].min
    limit = [max_distance, TRAP_SEARCH_DEAD_END_DISTANCE].min

    trap_detected = nil
    max_escape_options = 0

    1.upto(limit) do |distance|
      tile = result[distance]
      next if tile.nil?

      step_coord = [@position[0] + delta[0] * distance, @position[1] + delta[1] * distance]

      if tile == TILE_BLOCK || tile == TILE_CHARACTER
        trap_detected = { distance: distance, tile: tile }
        break
      elsif walkable_tile?(tile)
        escape_options = lateral_escape_option_count(step_coord, direction)
        max_escape_options = [max_escape_options, escape_options].max
      else
        # Unknownやその他のタイルが現れた場合は歩行範囲の評価を終了
        break
      end
    end

    if trap_detected
      entry[:blocked_distance] = trap_detected[:distance]
      run_length = trap_detected[:distance] - 1
      escape_available = max_escape_options >= TRAP_REQUIRED_ESCAPE_OPTIONS

      if run_length <= TRAP_DEAD_END_THRESHOLD && !escape_available
        mark_trap(coord, reason: :search)
        STDERR.puts "[smart] trap confirmed at #{coord.inspect} (distance=#{entry[:blocked_distance]})"
      else
        mark_safe(coord)
        STDERR.puts "[smart] trap escape path found at #{coord.inspect} (distance=#{entry[:blocked_distance]})"
      end
    else
      mark_safe(coord)
      STDERR.puts "[smart] trap cleared at #{coord.inspect}"
    end

    entry[:analyzed_turn] = @turn_count
    entry.delete(:requested_turn)
  end

  def lateral_escape_option_count(coord, forward_direction)
    return 0 unless coord

    perpendicular_dirs =
      case forward_direction
      when :up, :down
        [:left, :right]
      when :left, :right
        [:up, :down]
      else
        []
      end

    perpendicular_dirs.count do |dir|
      neighbor = coordinate_from(coord, dir)
      next false unless neighbor

      status = trap_status(neighbor)
      next false if [:confirmed_trap, :pending_search].include?(status)

      tile = @world[coord_key(neighbor)]
      walkable_tile?(tile)
    end
  end

  # マップ確定時に、マップ範囲外（1マス分）を壁として埋める
  def fill_boundary_walls
    return unless @localizer&.localized?

    # マップ周囲の絶対座標（幅+2, 高さ+2 の範囲）
    # 左端(-1), 右端(MAP_WIDTH), 上端(-1), 下端(MAP_HEIGHT) およびその四隅
    # Absolute Coordinates Range:
    # X: -1 .. MAP_WIDTH
    # Y: -1 .. MAP_HEIGHT
    
    # 上端・下端の行 (Y = -1, MAP_HEIGHT)
    [-1, MAP_HEIGHT].each do |ay|
      (-1..MAP_WIDTH).each do |ax|
        mark_boundary_wall(ax, ay)
      end
    end

    # 左端・右端の列 (X = -1, MAP_WIDTH)
    [-1, MAP_WIDTH].each do |ax|
      (0...MAP_HEIGHT).each do |ay| # 上下端は既に処理済み
        mark_boundary_wall(ax, ay)
      end
    end
    
    STDERR.puts "[map] Boundary walls filled around map."
  end

  def mark_boundary_wall(abs_x, abs_y)
    rel_coord = @localizer.to_relative([abs_x, abs_y])
    return unless rel_coord
    
    key = coord_key(rel_coord)
    # 既に観測済みの場合は上書きしない（基本的には未知か壁のはず）
    if @world[key].nil?
      @world[key] = TILE_BLOCK
    end
  end

  def self_trap_if_put?(grid, direction)
    return false unless direction

    adjacency = {}
    DIRECTIONS.each_key do |dir|
      adjacency[dir] = DIRECTIONS[dir][:index]
    end

    blocked_others = adjacency.reject { |dir, _| dir == direction }.count do |dir, idx|
      grid_blocked?(grid, idx)
    end
    target_index = adjacency[direction]
    target_blocked = target_index ? grid_blocked?(grid, target_index) : false
    blocked_others == 3 && !target_blocked
  end

  def block_history_limit_reached?(direction)
    history = @block_memory[coord_key(@position)]
    history.include?(direction) || history.size >= 3
  end

  def next_step_to_known_item
    bfs_direction { |pos| @world[coord_key(pos)] == TILE_ITEM }
  end

  def next_step_to_frontier
    bfs_direction do |pos|
      tile = @world[coord_key(pos)]
      next false unless walkable_tile?(tile)

      neighbors_at(pos).any? { |neighbor| @world[coord_key(neighbor)].nil? }
    end
  end

  # 訪問コスト付き優先度探索（ダイクストラベース）
  # 訪問回数が多い場所を避けつつ、目標に到達する経路を探索
  def bfs_direction
    return nil unless block_given?

    # 優先度付きキュー: [コスト, 座標, 最初の方向]
    open_set = [[0.0, @position, nil]]
    g_score = { coord_key(@position) => 0.0 }
    came_from = {}
    max_iterations = 300

    iterations = 0
    until open_set.empty?
      iterations += 1
      break if iterations > max_iterations

      # 最小コストのノードを取得
      open_set.sort_by! { |cost, _, _| cost }
      _, current, first_dir = open_set.shift
      current_key = coord_key(current)

      # ゴール判定
      if current != @position && yield(current)
        return first_dir || :up
      end

      DIRECTION_DELTAS.each do |dir, (dx, dy)|
        next_pos = [current[0] + dx, current[1] + dy]
        key = coord_key(next_pos)

        tile = @world[key]
        status = trap_status(next_pos)
        next if [:confirmed_trap, :pending_search].include?(status)
        next unless walkable_tile?(tile)

        # 訪問コストを計算（訪問回数が多いほどコスト増加）
        visit_cost = (@visit_counts[next_pos] || 0) * 0.5
        move_cost = 1.0 + visit_cost

        tentative_g = g_score[current_key] + move_cost

        if tentative_g < (g_score[key] || Float::INFINITY)
          g_score[key] = tentative_g
          initial_dir = first_dir || dir
          came_from[key] = { pos: current, dir: initial_dir }
          open_set << [tentative_g, next_pos, initial_dir]
        end
      end
    end

    nil
  end

  def walkable_tile?(tile)
    tile == TILE_EMPTY || tile == TILE_ITEM
  end

  def neighbors_at(pos)
    DIRECTION_DELTAS.values.map { |dx, dy| [pos[0] + dx, pos[1] + dy] }
  end

  def coordinate_in_direction(direction)
    delta = DIRECTION_DELTAS[direction]
    return nil unless delta

    [@position[0] + delta[0], @position[1] + delta[1]]
  end

  def apply_successful_walk(direction)
    delta = DIRECTION_DELTAS[direction]
    return unless delta

    new_pos = [@position[0] + delta[0], @position[1] + delta[1]]

    # アイテムを取得した場合はカウンター増加
    tile_at_new_pos = @world[coord_key(new_pos)]
    if tile_at_new_pos == TILE_ITEM
      @items_collected ||= 0
      @items_collected += 1
      # アイテム取得時は目標をクリア（次のターンで新しい目標を選択）
      clear_target_if_reached(new_pos)
    end

    @position = new_pos
    @visit_counts[@position] += 1
    @last_direction = direction
    track_recent_move(direction)

    # 目標に到達したかチェック
    check_target_reached
  end

  # ============================================================
  # 目標コミットメント機構
  # ============================================================

  # 目標を設定
  def set_target(coord, type, avoid_middle: false)
    @current_target = coord
    @last_target = coord # ヒステリシス用
    @target_type = type
    @target_commit_turns = 0
    @target_avoid_middle = avoid_middle
  end

  # 目標をクリア
  def clear_target
    @current_target = nil
    @target_type = nil
    @target_commit_turns = 0
    @target_avoid_middle = false
  end

  # 目標に到達したかチェック
  def check_target_reached
    return unless @current_target

    if @position == @current_target
      clear_target
    else
      @target_commit_turns += 1
      # 最大コミットターン数を超えたら目標を再評価
      clear_target if @target_commit_turns > @target_max_commit
    end
  end

  # アイテム取得時に目標をクリア
  def clear_target_if_reached(coord)
    return unless @current_target
    clear_target if @current_target == coord
  end

  # 現在の目標が有効かチェック
  def target_still_valid?
    return false unless @current_target

    case @target_type
    when :item
      # アイテムがまだ存在するか
      @world[coord_key(@current_target)] == TILE_ITEM
    when :frontier
      # 未探索エリアへの経路がまだ存在するか
      neighbors_at(@current_target).any? { |n| @world[coord_key(n)].nil? }
    else
      true
    end
  end

  # 目標への移動方向を取得
  def get_direction_to_target(enemy_positions = [])
    return nil unless @current_target && target_still_valid?

    # A*で目標への経路を探索
    astar_first_step(->(pos) { pos == @current_target }, enemy_positions, avoid_items: @target_avoid_middle)
  end

  def register_block(direction)
    coord = coordinate_in_direction(direction)
    @world[coord_key(coord)] = TILE_BLOCK if coord
  end

  def record_block_at_current_position(direction)
    @block_memory[coord_key(@position)] << direction
  end

  def action_success?(result)
    result.is_a?(Array) && !result.empty? && result[0] != 0
  end

  def track_recent_move(direction)
    return unless direction

    @recent_moves << direction
    @recent_moves.shift if @recent_moves.size > 12
  end

  def normalize_grid(vision)
    # vision が nil の場合は周辺情報を更新しない（既存 world を残す）
    return nil unless vision
    grid = Array.new(10, TILE_EMPTY)
    0.upto([9, vision.length - 1].min) do |i|
      grid[i] = vision[i] || TILE_EMPTY
    end
    grid
  end

  # ブロックを置く方向を選択する。安全な方向のみを返す。

  # 位置特定後に過去の観測データ全てに対して対称推論を再適用する
  def retroactive_symmetry_update
    return unless @localizer&.localized?
    
    STDERR.puts "[symmetry] Retroactive symmetry update triggered!"
    
    # 既存の全ての観測済みタイルについて対称推論を行う
    # （位置が未確定だったため推論されていなかった情報を補完）
    # Note: イテレーション中にハッシュを変更するため、keysのコピーを回す
    @world.keys.each do |key|
      tile = @world[key]
      coord = parse_coord_key(key)
      next unless coord
      next unless tile == TILE_BLOCK || tile == TILE_ITEM
      
      # 自分で置いたブロックは除外（マップ生成時のものではないため）
      next if tile == TILE_BLOCK && @self_placed_blocks.include?(key)
      
      # apply_symmetric_inference は重複チェックを行っているため安全
      apply_symmetric_inference(coord, tile)
    end
    
    # 過去に観測したアイテム（取得済みで@worldからは消えている場合も含む）についても対称推論
    @historical_items.each do |key|
      coord = parse_coord_key(key)
      next unless coord
      apply_symmetric_inference(coord, TILE_ITEM)
    end
  end
end
