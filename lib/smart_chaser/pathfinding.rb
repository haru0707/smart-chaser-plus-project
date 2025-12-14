# -*- coding: utf-8 -*-
# A*経路探索モジュール

class SmartChaser
  # ============================================================
  # 境界チェック統一ヘルパー
  # ============================================================
  #
  # 座標が「確実にマップ外」かどうかを判定する。
  # - @localizer が存在し位置特定済みの場合: definitely_out_of_map? を使用（探索範囲を広げる）
  # - それ以外の場合: out_of_bounds? を使用（保守的な判定）
  #
  # 戻り値:
  #   true  = 確実にマップ外（通行不可）
  #   false = マップ内の可能性あり（通行可能として扱う）
  #
  def coord_definitely_outside?(coord)
    return true unless coord
    
    if respond_to?(:definitely_out_of_map?) && @localizer
      definitely_out_of_map?(coord)
    else
      out_of_bounds?(coord)
    end
  end
  # 優先度付きキュー（簡易実装）
  class PriorityQueue
    def initialize
      @data = []
    end

    def push(item, priority)
      @data << [priority, item]
      @data.sort_by! { |p, _| p }
    end

    def pop
      return nil if @data.empty?
      @data.shift[1]
    end

    def empty?
      @data.empty?
    end

    def size
      @data.size
    end
  end

  # ============================================================
  # 連結性計算（袋小路回避用）
  # ============================================================
  
  # 指定座標から到達可能なマス数をBFSでカウント
  # limit: 計算打ち切り上限（パフォーマンス用）
  # 戻り値: 到達可能マス数（limitに達した場合はlimit）
  def count_reachable_tiles(start_coord, limit = 30)
    return 0 unless start_coord
    
    visited = Set.new
    queue = [start_coord]
    visited.add(coord_key(start_coord))
    
    count = 0
    while !queue.empty? && count < limit
      current = queue.shift
      count += 1
      
      DIRECTION_DELTAS.each do |_, (dx, dy)|
        neighbor = [current[0] + dx, current[1] + dy]
        neighbor_key = coord_key(neighbor)
        
        next if visited.include?(neighbor_key)
        next unless reachable_tile?(neighbor)
        
        visited.add(neighbor_key)
        queue << neighbor
      end
    end
    
    count
  end

  # タイルが到達可能（通行可能）かチェック
  def reachable_tile?(coord)
    return false unless coord
    return false if coord_definitely_outside?(coord)
    
    key = coord_key(coord)
    tile = @world[key]
    
    # 未知のタイルは対称推論を試みる（astar_walkable?と統一）
    if tile.nil?
      inferred = infer_tile_from_symmetry(coord)
      return false if inferred == TILE_BLOCK
      # 推論で空きタイルなら通行可能とみなす
      return true if inferred == TILE_EMPTY
      # 推論できない場合は探索可能とみなす（ただし端付近は除外）
      return !near_edge?(coord)
    end
    
    # ブロックとキャラクターは通行不可
    return false if tile == TILE_BLOCK || tile == TILE_CHARACTER
    
    # トラップは回避（astar_walkable?と同じ判定基準に統一）
    status = trap_status(coord)
    return false if [:confirmed_trap, :pending_search].include?(status)
    return false if trap_tile?(coord)
    
    true
  end

  # ============================================================
  # マップベース行き止まり・罠検知（サーチ不要）
  # ============================================================

  # 指定座標が行き止まりかどうかを判定
  # threshold: この数以下の到達可能マス数なら行き止まりとみなす
  def is_dead_end?(coord, threshold = 3)
    return true unless coord
    
    key = coord_key(coord)
    
    # キャッシュがあれば再利用（同一ターン内）
    @dead_end_cache ||= {}
    @dead_end_cache_turn ||= 0
    
    # ターンが変わったらキャッシュをクリア
    if @dead_end_cache_turn != @turn_count
      @dead_end_cache = {}
      @dead_end_cache_turn = @turn_count
    end
    
    return @dead_end_cache[key] if @dead_end_cache.key?(key)
    
    # BFSで連結性を計算（現在位置を除外するため、coordから開始）
    reachable = count_reachable_tiles_excluding_self(coord, threshold + 1)
    
    # キャッシュに保存
    @dead_end_cache[key] = reachable <= threshold
    
    @dead_end_cache[key]
  end

  # 自分の位置を除外した到達可能マス数をカウント
  def count_reachable_tiles_excluding_self(start_coord, limit = 30)
    return 0 unless start_coord
    
    visited = Set.new
    queue = [start_coord]
    visited.add(coord_key(start_coord))
    visited.add(coord_key(@position))  # 自分の位置を除外（進入後は戻れない想定）
    
    count = 0
    while !queue.empty? && count < limit
      current = queue.shift
      count += 1
      
      DIRECTION_DELTAS.each do |_, (dx, dy)|
        neighbor = [current[0] + dx, current[1] + dy]
        neighbor_key = coord_key(neighbor)
        
        next if visited.include?(neighbor_key)
        next unless reachable_tile?(neighbor)
        
        visited.add(neighbor_key)
        queue << neighbor
      end
    end
    
    count
  end

  # マップデータから罠（袋小路アイテム）を検知
  # アイテムがある位置で、進入後の退路が少なければ罠の可能性が高い
  def detect_trap_from_map(coord)
    return false unless coord
    
    key = coord_key(coord)
    tile = @world[key]
    
    # アイテムがある位置のみチェック
    return false unless tile == TILE_ITEM
    
    # 進入後の退路を確認（2マス以下なら罠の可能性）
    is_dead_end?(coord, 2)
  end

  # A*経路探索で目標への最初の一歩を返す
  # 探索ノード数に制限を設け、無限ループを防止
  # 方向継続ボーナス: 直進を優先してジグザグを抑制
  # avoid_items: trueの場合、ゴール以外のアイテムを踏むことにペナルティを課す
  def astar_first_step(goal_condition, enemy_positions = [], avoid_items: false)
    open = PriorityQueue.new
    open.push(@position, 0)
    
    g_score = { coord_key(@position) => 0.0 }
    came_from = {}  # coord_key => { pos: [x,y], dir: :symbol }
    direction_at = { coord_key(@position) => @last_direction }  # 各ノードでの進行方向
    closed = Set.new  # 探索済みノード
    
    max_iterations = 500  # 探索制限
    iterations = 0
    
    until open.empty?
      iterations += 1
      break if iterations > max_iterations  # 無限ループ防止
      
      current = open.pop
      current_key = coord_key(current)
      
      # 既に探索済みならスキップ
      next if closed.include?(current_key)
      closed.add(current_key)
      
      # ゴール判定
      if current != @position && goal_condition.call(current)
        return reconstruct_first_step(came_from, current)
      end
      
      DIRECTION_DELTAS.each do |dir, (dx, dy)|
        neighbor = [current[0] + dx, current[1] + dy]
        neighbor_key = coord_key(neighbor)
        
        # 既に探索済みならスキップ
        next if closed.include?(neighbor_key)
        
        # 通行可能チェック
        next unless astar_walkable?(neighbor)
        
        # コスト計算（敵接近ペナルティ含む）
        move_cost = 1.0
        move_cost += enemy_proximity_penalty(neighbor, enemy_positions)
        move_cost += visit_penalty(neighbor)
        
        # アイテム踏み越えペナルティ（条件付き）
        # avoid_itemsが有効な場合のみ、ゴール以外のアイテムを踏むことを避ける
        if avoid_items
          tile = @world[neighbor_key]
          if tile == TILE_ITEM && !goal_condition.call(neighbor)
            move_cost += 2.0
          end
        end

        # 方向継続ボーナス（直進を優先してジグザグを防止）
        prev_dir = direction_at[current_key]
        if prev_dir && prev_dir != dir
          move_cost += 0.3  # 方向転換にペナルティ
        end
        
        tentative_g = g_score[current_key] + move_cost
        
        if tentative_g < (g_score[neighbor_key] || Float::INFINITY)
          came_from[neighbor_key] = { pos: current.dup, dir: dir }
          direction_at[neighbor_key] = dir  # このノードでの進行方向を記録
          g_score[neighbor_key] = tentative_g
          h = astar_heuristic(neighbor, goal_condition)
          f = tentative_g + h
          open.push(neighbor, f)
        end
      end
    end
    
    nil  # 経路なし
  end

  # 指定座標への経路コストを計算（A*使用）
  # 経路が見つからない場合は nil を返す
  def astar_path_cost(target_coord, enemy_positions = [], avoid_items: false)
    return nil unless target_coord
    
    # 目標が壁なら到達不可
    return nil if @world[coord_key(target_coord)] == TILE_BLOCK

    goal_condition = ->(pos) { pos == target_coord }
    
    open = PriorityQueue.new
    open.push(@position, 0)
    
    g_score = { coord_key(@position) => 0.0 }
    direction_at = { coord_key(@position) => @last_direction }
    closed = Set.new
    
    max_iterations = 500
    iterations = 0
    
    until open.empty?
      iterations += 1
      break if iterations > max_iterations
      
      current = open.pop
      current_key = coord_key(current)
      
      next if closed.include?(current_key)
      closed.add(current_key)
      
      # ゴール到達：コストを返す
      if current == target_coord
        return g_score[current_key]
      end
      
      DIRECTION_DELTAS.each do |dir, (dx, dy)|
        neighbor = [current[0] + dx, current[1] + dy]
        neighbor_key = coord_key(neighbor)
        
        next if closed.include?(neighbor_key)
        next unless astar_walkable?(neighbor)
        
        move_cost = 1.0
        move_cost += enemy_proximity_penalty(neighbor, enemy_positions)
        move_cost += visit_penalty(neighbor)
        
        if avoid_items
          tile = @world[neighbor_key]
          if tile == TILE_ITEM && !goal_condition.call(neighbor)
            move_cost += 2.0
          end
        end

        prev_dir = direction_at[current_key]
        if prev_dir && prev_dir != dir
          move_cost += 0.3
        end
        
        tentative_g = g_score[current_key] + move_cost
        
        if tentative_g < (g_score[neighbor_key] || Float::INFINITY)
          g_score[neighbor_key] = tentative_g
          h = manhattan_distance(neighbor, target_coord)
          f = tentative_g + h
          open.push(neighbor, f)
          direction_at[neighbor_key] = dir
        end
      end
    end
    
    nil
  end

  # 経路から最初の一歩を抽出
  def reconstruct_first_step(came_from, goal)
    current = goal
    first_step = nil
    
    while came_from[coord_key(current)]
      entry = came_from[coord_key(current)]
      first_step = entry[:dir]
      current = entry[:pos]
    end
    
    first_step
  end

  # A*用通行可能判定（対称推論対応）
  def astar_walkable?(coord)
    return false unless coord
    
    # 境界外チェック（統一ヘルパー使用）
    return false if coord_definitely_outside?(coord)
    
    key = coord_key(coord)
    tile = @world[key]
    
    # 未知のタイルは対称推論を試みる
    if tile.nil?
      inferred = infer_tile_from_symmetry(coord)
      return false if inferred == TILE_BLOCK
      # 推論で空きタイルなら通行可能とみなす
      return true if inferred == TILE_EMPTY
      # 推論できない場合は探索可能とみなす（ただし端付近は除外）
      return !near_edge?(coord)
    end
    
    # ブロック・敵は通行不可
    return false if tile == TILE_BLOCK || tile == TILE_CHARACTER
    
    # トラップチェック（reachable_tile?と同じ判定基準に統一）
    status = trap_status(coord)
    return false if [:confirmed_trap, :pending_search].include?(status)
    return false if trap_tile?(coord)
    
    true
  end

  # ヒューリスティック関数（ゴールまでの推定コスト）
  def astar_heuristic(coord, goal_condition)
    # アイテム探索の場合は既知のアイテムまでの距離
    # それ以外は0（ダイクストラ法相当）
    
    # 最寄りのアイテムまでの距離を計算
    nearest_item_dist = Float::INFINITY
    @world.each do |key, tile|
      next unless tile == TILE_ITEM
      item_coord = parse_coord_key(key)
      next unless item_coord
      dist = manhattan_distance(coord, item_coord)
      nearest_item_dist = [nearest_item_dist, dist].min
    end
    
    nearest_item_dist == Float::INFINITY ? 0 : nearest_item_dist * 0.5
  end

  # 敵接近ペナルティ（ヒートマップ対応）
  # ヒートマップからの回避を強化
  def enemy_proximity_penalty(coord, enemy_positions)
    penalty = 0.0
    
    # 1. 確定的な敵位置からの距離ペナルティ
    unless enemy_positions.empty?
      min_dist = enemy_positions.map { |ep| manhattan_distance(coord, ep) }.min
      case min_dist
      when 0 then penalty += 100.0  # 敵と同じ位置は絶対回避
      when 1 then penalty += 30.0   # 隣接は非常に危険
      when 2 then penalty += 10.0   # 2マスも危険
      when 3 then penalty += 3.0    # 3マスも軽度ペナルティ
      end
    end

    # 2. 確率的な敵位置（ヒートマップ）からのペナルティ
    # 確率0.1以上でペナルティを適用（強化版）
    prob = get_enemy_probability(coord) || 0.0
    if prob > 0.1
      # 確率に応じた強いペナルティ
      # 確率1.0なら20ポイント、0.5なら10ポイント
      penalty += prob * 20.0
    end
    
    # 3. 周囲のヒートマップ確率も考慮（敵が近くにいる可能性を検知）
    neighbors_prob = DIRECTION_DELTAS.values.map do |(dx, dy)|
      neighbor = [coord[0] + dx, coord[1] + dy]
      get_enemy_probability(neighbor) || 0.0
    end.max
    
    if neighbors_prob > 0.2
      penalty += neighbors_prob * 5.0
    end

    penalty
  end

  # 訪問ペナルティ（係数を0.5に増加して再訪問を抑制）
  def visit_penalty(coord)
    (@visit_counts[coord] || 0) * 0.5
  end

  # A*でアイテムへの経路を探索
  def astar_to_nearest_item(enemy_positions = [], avoid_items: false)
    astar_first_step(->(pos) { @world[coord_key(pos)] == TILE_ITEM }, enemy_positions, avoid_items: avoid_items)
  end

  # A*で未探索エリアへの経路を探索（対称情報考慮）
  def astar_to_frontier(enemy_positions = [])
    # 優先度ベースの探索を試みる
    sym_result = astar_to_frontier_symmetric(enemy_positions) if respond_to?(:astar_to_frontier_symmetric)
    return sym_result if sym_result
    
    # フォールバック: 従来の探索
    # フォールバック1: 真に未知のタイルへ向かう
    astar_first_step(
      ->(pos) {
        tile = @world[coord_key(pos)]
        return false unless tile == TILE_EMPTY || tile == TILE_ITEM
        return false if coord_definitely_outside?(pos)
        # 真に未知のタイル（対称推論でも分からない）を優先
        neighbors_at(pos).any? { |n| !coord_definitely_outside?(n) && is_truly_unknown?(n) }
      },
      enemy_positions
    ) || 
    # フォールバック2: 未観測タイルへ向かう
    astar_first_step(
      ->(pos) {
        tile = @world[coord_key(pos)]
        return false unless tile == TILE_EMPTY || tile == TILE_ITEM
        return false if coord_definitely_outside?(pos)
        neighbors_at(pos).any? { |n| !coord_definitely_outside?(n) && @world[coord_key(n)].nil? }
      },
      enemy_positions
    )
  end
end
