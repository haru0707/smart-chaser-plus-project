# -*- coding: utf-8 -*-
# 攻撃戦略モジュール（ミニマックス含む）

class SmartChaser
  # 攻撃行動を評価（戦略対応版）
  # strategy: 現在の戦略モード（:aggressive, :defensive, :item_focus, :exploration, :balanced）
  def evaluate_attack_opportunity(grid, enemy_positions, strategy = nil)
    return nil if enemy_positions.empty?
    
    strategy ||= @current_strategy || :balanced
    
    # 戦略に基づく閾値調整
    thresholds = attack_thresholds_for_strategy(strategy)
    
    enemy_pos = enemy_positions.first
    enemy_dirs = directions_to_positions(enemy_positions)
    
    # 1. 直接攻撃（敵の上にブロック）= 即勝利（常に優先）
    direct_kill = evaluate_direct_kill(grid, enemy_dirs)
    return direct_kill if direct_kill && direct_kill[:score] >= 100
    
    # 2. 囲い込み攻撃（戦略に応じた閾値 + ヒステリシス補正）
    encircle = evaluate_encirclement_attack(grid, enemy_pos)
    effective_encircle_threshold = thresholds[:encircle] - hysteresis_threshold_bonus
    if encircle && encircle[:score] >= effective_encircle_threshold
      hysteresis_note = should_sustain_attack? ? "（攻撃継続）" : ""
      encircle[:reason] = "#{encircle[:reason]}（#{strategy_name_japanese}モード）#{hysteresis_note}"
      return encircle
    end
    
    # 3. 追い詰め戦略（戦略に応じた閾値 + ヒステリシス補正）
    cornering = evaluate_cornering_strategy(grid, enemy_pos)
    effective_cornering_threshold = thresholds[:cornering] - hysteresis_threshold_bonus
    if cornering && cornering[:score] >= effective_cornering_threshold
      hysteresis_note = should_sustain_attack? ? "（攻撃継続）" : ""
      cornering[:reason] = "#{cornering[:reason]}（#{strategy_name_japanese}モード）#{hysteresis_note}"
      return cornering
    end
    
    nil
  end

  # 戦略に基づく攻撃閾値を返す
  def attack_thresholds_for_strategy(strategy)
    case strategy
    when :aggressive
      { encircle: 60, cornering: 35 }  # 積極的に攻撃
    when :defensive
      { encircle: 90, cornering: 70 }  # 確実な場合のみ攻撃
    when :item_focus
      { encircle: 85, cornering: 60 }  # アイテム優先、好機のみ攻撃
    when :exploration
      { encircle: 80, cornering: 55 }  # 探索優先、通常閾値
    else  # :balanced
      { encircle: 80, cornering: 50 }  # 現在の動作を維持
    end
  end

  # 現在の戦略の日本語名を返す
  def strategy_name_japanese
    case @current_strategy
    when :aggressive
      "積極攻撃"
    when :defensive
      "防御重視"
    when :item_focus
      "アイテム優先"
    when :exploration
      "探索優先"
    else
      "バランス"
    end
  end

  # 攻撃継続すべきかを判定（ヒステリシス）
  # 直近のターンで攻撃していた場合、閾値を下げて攻撃継続を促す
  def should_sustain_attack?
    return false unless @last_attack_turn
    # 2ターン以内に攻撃していれば継続判定
    (@turn_count - @last_attack_turn) <= 2
  end

  # ヒステリシスを考慮した閾値補正
  def hysteresis_threshold_bonus
    should_sustain_attack? ? 15 : 0  # 継続時は閾値を15pt下げる
  end

  # 直接攻撃（敵上にブロック）
  def evaluate_direct_kill(grid, enemy_dirs)
    enemy_dirs.each do |dir|
      tile = grid[DIRECTIONS[dir][:index]]
      if tile == TILE_CHARACTER
        return {
          action: action(:put, dir),
          score: 100,
          reason: "敵の上に直接ブロック設置で即勝利"
        }
      end
    end
    nil
  end

  # 囲い込み攻撃評価
  def evaluate_encirclement_attack(grid, enemy_pos)
    # 敵の逃げ道を数える
    escape_routes = enemy_escape_route_count(grid, enemy_pos)

    # 既に囲まれている場合は攻撃不要（nilを返して通常行動に移行）
    # action: nil を返すとクラッシュするため、nilを返す
    return nil if escape_routes == 0
    
    # 1手で囲い込み完了可能かチェック
    best_block = nil
    DIRECTIONS.each_key do |dir|
      coord = coordinate_in_direction(dir)
      next unless coord
      next unless can_put_block_there?(grid, dir)
      
      # ブロック設置後の敵逃げ道をシミュレート
      simulated_routes = simulate_enemy_routes_after_block(grid, enemy_pos, dir)
      
      if simulated_routes == 0
        return {
          action: action(:put, dir),
          score: 85,
          reason: "ブロック設置で敵を完全に囲い込み"
        }
      elsif simulated_routes < escape_routes
        improvement = escape_routes - simulated_routes
        score = 60 + improvement * 10
        if best_block.nil? || score > best_block[:score]
          best_block = {
            action: action(:put, dir),
            score: score,
            reason: "敵の逃げ道を#{improvement}つ減少（#{escape_routes}→#{simulated_routes}）"
          }
        end
      end
    end
    
    best_block
  end

  # ブロック設置後の敵逃げ道をシミュレート
  def simulate_enemy_routes_after_block(grid, enemy_pos, block_dir)
    block_coord = coordinate_in_direction(block_dir)
    return enemy_escape_route_count(grid, enemy_pos) unless block_coord
    
    # 仮想グリッドでシミュレート
    DIRECTIONS.keys.count do |dir|
      next_coord = coordinate_from(enemy_pos, dir)
      next false unless next_coord
      next false if next_coord == @position
      next false if next_coord == block_coord  # 新しいブロック
      
      tile = tile_from_memory(grid, next_coord)
      walkable_for_enemy_tile?(tile)
    end
  end

  # 追い詰め戦略（Voronoi領域支配率ベース）
  def evaluate_cornering_strategy(grid, enemy_pos)
    best_move = nil
    
    DIRECTIONS.each_key do |dir|
      coord = coordinate_in_direction(dir)
      next unless coord
      next unless front_walkable?(grid, dir)
      next if would_trap_on_move?(dir, grid)
      
      # 安全確認
      next unless safe_position_against_enemies?(coord, grid)
      
      # Voronoi領域支配率を計算
      # 自分と敵が同時にBFS探索を行い、到達可能なマス数を競う
      voronoi_score = calculate_voronoi_score(grid, coord, enemy_pos)
      
      # 支配領域が大きいほど有利
      score = 40 + voronoi_score * 2
      
      if best_move.nil? || score > best_move[:score]
        best_move = {
          action: action(:walk, dir),
          score: score,
          reason: "領域支配率重視（スコア: #{voronoi_score}）"
        }
      end
    end
    
    best_move
  end

  # Voronoi領域スコア計算（自分の支配領域 - 敵の支配領域）
  def calculate_voronoi_score(grid, my_start, enemy_start)
    my_queue = [[my_start, 0]]
    enemy_queue = [[enemy_start, 0]]
    
    my_visited = { coord_key(my_start) => 0 }
    enemy_visited = { coord_key(enemy_start) => 0 }
    
    my_territory = 0
    enemy_territory = 0
    
    # 双方の探索キューが空になるまで（または一定距離まで）

    
    while !my_queue.empty? || !enemy_queue.empty?
      # 自分のターン
      if !my_queue.empty?
        curr, dist = my_queue.shift
        
        my_territory += 1 unless enemy_visited.key?(coord_key(curr)) && enemy_visited[coord_key(curr)] <= dist
        
        neighbors_at(curr).each do |n|
          key = coord_key(n)
          next if my_visited.key?(key)
          next unless walkable_tile?(@world[key])
          next if grid_blocked_at?(grid, n)
          
          my_visited[key] = dist + 1
          my_queue << [n, dist + 1]
        end
      end
      
      # 敵のターン
      if !enemy_queue.empty?
        curr, dist = enemy_queue.shift
        
        enemy_territory += 1 unless my_visited.key?(coord_key(curr)) && my_visited[coord_key(curr)] <= dist
        
        neighbors_at(curr).each do |n|
          key = coord_key(n)
          next if enemy_visited.key?(key)
          next unless walkable_tile?(@world[key])
          next if grid_blocked_at?(grid, n)
          
          enemy_visited[key] = dist + 1
          enemy_queue << [n, dist + 1]
        end
      end
    end
    
    my_territory - enemy_territory
  end

  def grid_blocked_at?(grid, coord)
    offset = [coord[0] - @position[0], coord[1] - @position[1]]
    index = OFFSET_TO_INDEX[offset]
    return false unless index
    
    tile = grid[index]
    tile == TILE_BLOCK || tile == TILE_CHARACTER
  end

  # ミニマックス評価（2手先読み）
  def minimax_evaluate(grid, my_action, depth = 2)
    return evaluate_position(grid) if depth == 0
    
    # 自分の行動をシミュレート
    simulated_grid = simulate_action(grid, my_action)
    
    # 敵の最善応答を仮定
    worst_case = Float::INFINITY
    DIRECTIONS.each_key do |enemy_dir|
      enemy_action = { verb: :walk, direction: enemy_dir }
      enemy_grid = simulate_enemy_action(simulated_grid, enemy_action)
      
      score = minimax_evaluate(enemy_grid, nil, depth - 1)
      worst_case = [worst_case, score].min
    end
    
    worst_case
  end

  # 現在位置の評価
  def evaluate_position(grid)
    score = 0.0
    
    # 自由度
    score += free_neighbor_count(@position) * 5
    
    # アイテム近接ボーナス
    @world.each do |key, tile|
      next unless tile == TILE_ITEM
      coord = parse_coord_key(key)
      next unless coord
      dist = manhattan_distance(@position, coord)
      score += 10.0 / (dist + 1)
    end
    
    # 敵から離れているボーナス
    if @enemy_predicted_pos
      dist = manhattan_distance(@position, @enemy_predicted_pos)
      score += dist * 2
    end
    
    score
  end

  # アクションシミュレート（簡易版）
  def simulate_action(grid, the_action)
    return grid unless the_action
    
    simulated = grid.dup
    case the_action[:verb]
    when :put
      index = DIRECTIONS[the_action[:direction]][:index]
      simulated[index] = TILE_BLOCK if simulated[index] == TILE_EMPTY
    end
    simulated
  end

  # 敵アクションシミュレート（簡易版）
  def simulate_enemy_action(grid, the_action)
    # 簡易的に敵の移動をシミュレート
    grid.dup
  end

  # 座標から方向を取得
  def directions_to_positions(positions)
    positions.filter_map do |pos|
      dx = pos[0] - @position[0]
      dy = pos[1] - @position[1]
      
      case [dx, dy]
      when [0, -1] then :up
      when [0, 1] then :down
      when [-1, 0] then :left
      when [1, 0] then :right
      else nil
      end
    end
  end
end
