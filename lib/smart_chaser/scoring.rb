# -*- coding: utf-8 -*-
# 得点最適化モジュール

class SmartChaser
  # 得点計算
  def calculate_score(items, remaining_turns, is_win)
    base = items * ITEM_SCORE_MULTIPLIER
    is_win ? base + remaining_turns : base - remaining_turns
  end

  # 現在の推定得点
  def current_estimated_score(remaining_turns)
    # 勝利の場合
    calculate_score(@items_collected, remaining_turns, true)
  end

  # 戦略モードを決定（ヒステリシス対応版）
  def determine_strategy_mode(remaining_turns)
    item_advantage = @items_collected - estimate_enemy_items
    turn_progress = 1.0 - (remaining_turns.to_f / MAX_TURNS)
    
    new_strategy = if item_advantage > 3
      :defensive  # 大幅リードなら守備的
    elsif item_advantage < -2
      :aggressive  # 負けているなら攻撃的
    elsif turn_progress > 0.7
      :item_focus  # 終盤はアイテム集中
    elsif turn_progress < 0.3
      :exploration  # 序盤は探索重視
    else
      :balanced  # 中盤はバランス
    end
    
    # ヒステリシス: 戦略変更の閾値を設ける
    # 現在の戦略と新しい戦略が異なる場合、条件が「強く」満たされている場合のみ変更
    if should_change_strategy?(new_strategy, item_advantage, turn_progress)
      @current_strategy = new_strategy
    end
    
    @current_strategy
  end

  # 戦略変更すべきかを判定（ヒステリシス）
  def should_change_strategy?(new_strategy, item_advantage, turn_progress)
    return true if @current_strategy.nil?
    return true if @current_strategy == new_strategy
    
    # 境界付近での頻繁な切り替えを防ぐ
    case new_strategy
    when :defensive
      item_advantage > 4  # 通常3だが、4以上で変更
    when :aggressive
      item_advantage < -3  # 通常-2だが、-3以下で変更
    when :item_focus
      turn_progress > 0.75  # 通常0.7だが、0.75以上で変更
    when :exploration
      turn_progress < 0.25  # 通常0.3だが、0.25以下で変更
    else
      true  # balancedへの変更は常に許可
    end
  end

  # 戦略に基づく重み付け
  def strategy_weights
    case @current_strategy
    when :defensive
      { escape: 2.0, attack: 0.5, item: 0.8, explore: 0.3 }
    when :aggressive
      { escape: 0.8, attack: 2.0, item: 0.5, explore: 0.3 }
    when :item_focus
      { escape: 1.0, attack: 0.8, item: 2.0, explore: 0.2 }
    when :exploration
      { escape: 1.0, attack: 0.5, item: 1.0, explore: 2.0 }
    else  # balanced
      { escape: 1.0, attack: 1.0, item: 1.0, explore: 1.0 }
    end
  end

  # 早期決着のメリットを計算
  def early_finish_value(remaining_turns)
    # 勝利確定時は早期決着がボーナスになる
    remaining_turns * 0.5
  end

  # リスク許容度
  def risk_tolerance
    case @current_strategy
    when :defensive then 0.3  # リスク回避
    when :aggressive then 0.8  # リスク許容
    when :item_focus then 0.5
    else 0.5
    end
  end

  # 戦略名を日本語で取得
  def strategy_name_japanese
    case @current_strategy
    when :defensive then "守備重視"
    when :aggressive then "攻撃重視"
    when :item_focus then "アイテム収集"
    when :exploration then "探索重視"
    else "バランス"
    end
  end

  # 残りターン数を推定
  def estimate_remaining_turns
    # 実際のターン数は不明なので、中央値を使用して推定
    estimated_total = (MIN_TURNS + MAX_TURNS) / 2
    [estimated_total - @turn_count, 0].max
  end

  # ============================================================
  # アイテム収集 vs 探索の期待値計算
  # ============================================================

  # アイテム密度（観測した全タイル中のアイテム割合）
  def item_density
    @observed_items ||= 0
    @observed_tiles ||= 0
    return 0.05 if @observed_tiles < 10  # 初期値
    @observed_items.to_f / @observed_tiles
  end

  # アイテム観測を記録（update_world_stateから呼ぶ）
  def record_tile_observation(tile)
    @observed_tiles ||= 0
    @observed_items ||= 0
    @observed_tiles += 1
    @observed_items += 1 if tile == TILE_ITEM
  end

  # 既知アイテムの効率（Points per Turn）
  # E_item = ItemScore / (Distance + RiskPenalty)
  def calculate_item_efficiency(distance, risk_penalty = 0)
    return 0.0 if distance <= 0
    item_score = ITEM_SCORE_MULTIPLIER * 10.0  # 基礎点 30
    item_score / (distance + risk_penalty + 1.0)
  end

  # 探索の期待値
  # E_explore = ItemScore * P_density * N_reveal * dampening_factor
  # 抑制係数を導入して探索を過度に優先しないようにする
  def calculate_exploration_efficiency(new_tiles_count)
    return 0.0 if new_tiles_count <= 0
    item_score = ITEM_SCORE_MULTIPLIER * 10.0
    
    # 抑制係数: 探索の楽観的すぎる評価を抑える
    dampening_factor = 0.5
    
    # 新規タイル数に対数スケーリングを適用（大量の新規タイルでも過大評価しない）
    scaled_tiles = Math.log2(new_tiles_count + 1)
    
    item_score * item_density * scaled_tiles * dampening_factor
  end

  # 探索 vs アイテム取得の判断
  # 既知のアイテムへ行くべきか、探索すべきかを判定
  def should_explore_instead_of_item?(item_distance, new_tiles_estimate)
    # 未探索率を計算
    unexplored_ratio = calculate_unexplored_ratio

    # 未探索率が20%以上かつ、アイテムまで12手以上なら探索優先
    # それ以外はアイテムを取りに行く
    if unexplored_ratio >= 0.20 && item_distance >= 12
      return true
    end

    # それ以外はアイテム優先
    false
  end

  # 未探索率を計算（0.0〜1.0）
  def calculate_unexplored_ratio
    total_map_tiles = MAP_WIDTH * MAP_HEIGHT
    explored_tiles = @world.count { |_, tile| !tile.nil? }
    unexplored = total_map_tiles - explored_tiles
    unexplored.to_f / total_map_tiles
  end

  # 未探索タイルの総数を概算
  def count_total_unexplored_tiles
    total_map_tiles = MAP_WIDTH * MAP_HEIGHT
    explored_tiles = @world.count { |_, tile| !tile.nil? }
    total_map_tiles - explored_tiles
  end

  # 最も効率的なアイテムを選択（TSP的アプローチ）
  # 複数の既知アイテムから、巡回効率と到達コストを考慮して最適なものを選ぶ
  # 3つ以上直線に並んでいるアイテムは端から取るようにする（距離差が2手以内の場合）
  def best_item_target
    item_coords = collect_all_item_coords
    return nil if item_coords.empty?

    # アイテムが1つの場合は単純に選択
    if item_coords.size == 1
      coord = item_coords.first
      return create_item_target_info(coord)
    end

    # 複数アイテムがある場合、巡回計画を考慮
    # まず、全アイテムの基本情報を計算
    scored_items = item_coords.map do |coord|
      create_item_target_info(coord)
    end

    # 罠や袋小路を除外
    safe_items = scored_items.reject { |item| item[:connectivity] <= 2 }
    safe_items = scored_items if safe_items.empty?  # 全て危険なら仕方ない

    # 直線状アイテム列の端を優先（両端比較 & ヒステリシス）
    edges = find_edge_item_in_line(safe_items)
    if edges
      candidates = [edges[:end1], edges[:end2]]
      
      # 敵位置情報の取得
      enemy_positions = @enemy_tracker ? @enemy_tracker.enemy_positions : []

      # 両端のコストを評価
      best_edge_result = candidates.map do |candidate|
        # 中央回避モードでの実際の移動コストを計算
        cost = astar_path_cost(candidate[:coord], enemy_positions, avoid_items: true)
        
        if cost
          # ヒステリシス: 前回と同じターゲットならコスト割引（ふらつき防止）
          # コスト -2.0 相当（約2歩分のマージン）
          cost -= 2.0 if @last_target == candidate[:coord]
        end
        
        { item: candidate, cost: cost }
      end.select { |r| r[:cost] }.min_by { |r| r[:cost] }

      # 有効な経路がある端が見つかればそれを採用
      if best_edge_result
        target = best_edge_result[:item]
        target[:avoid_middle] = true
        return target
      end
      
      # 両端とも到達不能（またはコスト無限）の場合は、以下の通常ロジックにフォールバック
      # ユーザーの要望「そっちでも詰まったら諦めて普通に取る」に対応
    end

    # TSP最適化: ニアレストネイバー法でルートを計画
    route = plan_item_collection_route(safe_items.map { |i| i[:coord] })

    # 計画されたルートの最初のアイテムを選択
    if route && !route.empty?
      first_target = route.first
      target_item = safe_items.find { |i| i[:coord] == first_target }
      return target_item if target_item
    end

    # フォールバック: 効率が最も高いアイテムを選択
    safe_items.max_by { |item| item[:efficiency] }
  end

  # 直線状のアイテム列を検出し、その両端のアイテムを返す
  # 戻り値: { end1: item_info, end2: item_info } または nil
  def find_edge_item_in_line(item_infos)
    return nil if item_infos.size < 3

    item_coords = item_infos.map { |i| i[:coord] }

    # 各アイテムについて、直線状に並んでいるかチェック
    item_infos.each do |item|
      coord = item[:coord]
      
      DIRECTION_DELTAS.each do |dir, (dx, dy)|
        # この方向で直線状にアイテムが並んでいるかチェック
        line_items = [coord]
        
        # 正方向にアイテムを探す
        current = coord
        loop do
          next_coord = [current[0] + dx, current[1] + dy]
          break unless item_coords.include?(next_coord)
          line_items << next_coord
          current = next_coord
        end
        
        # 反対方向にもアイテムを探す
        current = coord
        loop do
          prev_coord = [current[0] - dx, current[1] - dy]
          break unless item_coords.include?(prev_coord)
          line_items.unshift(prev_coord)
          current = prev_coord
        end
        
        # 3つ以上並んでいたら、両端のアイテムを返す
        if line_items.size >= 3
          first_edge_coord = line_items.first
          last_edge_coord = line_items.last
          
          first_info = item_infos.find { |i| i[:coord] == first_edge_coord }
          last_info = item_infos.find { |i| i[:coord] == last_edge_coord }

          return { end1: first_info, end2: last_info }
        end
      end
    end
    
    nil
  end

  # 全アイテム座標を収集
  def collect_all_item_coords
    coords = []
    @world.each do |key, tile|
      next unless tile == TILE_ITEM
      coord = parse_coord_key(key)
      coords << coord if coord
    end
    coords
  end

  # アイテムターゲット情報を作成
  def create_item_target_info(coord)
    dist = manhattan_distance(@position, coord)
    base_efficiency = calculate_item_efficiency(dist)

    # 連結性スコア: アイテム取得後の到達可能マス数
    connectivity = count_reachable_tiles(coord, 15)

    # 袋小路ペナルティ
    connectivity_factor = case connectivity
      when 0..2 then 0.1   # 罠（ほぼ確実に自滅）
      when 3..4 then 0.3   # 袋小路
      when 5..7 then 0.6   # 狭いエリア
      when 8..12 then 0.85 # やや狭い
      else 1.0             # 十分な広さ
    end

    # 訪問回数によるペナルティ（何度も通った経路上のアイテムは後回し）
    visit_penalty_factor = 1.0 / (1.0 + (@visit_counts[coord] || 0) * 0.2)

    final_efficiency = base_efficiency * connectivity_factor * visit_penalty_factor

    { coord: coord, distance: dist, efficiency: final_efficiency, connectivity: connectivity }
  end

  # TSP的アプローチ: ニアレストネイバー法でアイテム巡回ルートを計画
  # 現在位置から最も近いアイテムを順に選び、全体の移動距離を最小化
  def plan_item_collection_route(item_coords)
    return [] if item_coords.empty?
    return item_coords if item_coords.size == 1

    route = []
    remaining = item_coords.dup
    current_pos = @position.dup

    while remaining.any?
      # 現在位置から最も近いアイテムを選択
      # ただし、経路上の訪問回数も考慮
      best_next = remaining.min_by do |coord|
        base_dist = manhattan_distance(current_pos, coord)

        # 経路上の訪問回数を概算（直線距離に基づく）
        path_visit_penalty = estimate_path_visit_cost(current_pos, coord)

        # 連結性も考慮（袋小路は後回し）
        connectivity = count_reachable_tiles(coord, 10)
        connectivity_penalty = connectivity < 5 ? 3.0 : 0.0

        base_dist + path_visit_penalty * 0.3 + connectivity_penalty
      end

      route << best_next
      current_pos = best_next
      remaining.delete(best_next)
    end

    route
  end

  # 2点間の経路上の訪問コストを概算
  def estimate_path_visit_cost(from, to)
    return 0 unless from && to

    # 簡易的に直線上のマスの訪問回数を合計
    dx = to[0] - from[0]
    dy = to[1] - from[1]
    steps = [dx.abs, dy.abs].max
    return 0 if steps == 0

    total_cost = 0
    (1..steps).each do |i|
      ratio = i.to_f / steps
      x = from[0] + (dx * ratio).round
      y = from[1] + (dy * ratio).round
      total_cost += @visit_counts[[x, y]] || 0
    end

    total_cost
  end

  # 探索方向ごとの新規タイル数を推定
  def estimate_new_tiles_in_direction(direction)
    delta = DIRECTION_DELTAS[direction]
    return 0 unless delta
    
    count = 0
    (1..9).each do |dist|
      coord = [@position[0] + delta[0] * dist, @position[1] + delta[1] * dist]
      count += 1 if @world[coord_key(coord)].nil?
    end
    count
  end
end
