# -*- coding: utf-8 -*-
# 敵追跡・予測モジュール
# U-16プロコン北海道大会対応（マップ点対称を活用）

module EnemyTrackerBehavior
  # 定数定義
  HISTORY_LIMIT = 20
  PROBABILITY_THRESHOLD = 0.01
  RECENT_SIGHTING_THRESHOLD = 2
  ESTIMATED_ITEM_FACTOR = 0.8

  # 敵追跡システムを初期化
  def init_enemy_tracker
    @initial_position = @position.dup
    @enemy_sightings = []  # 敵目撃履歴 [{turn:, pos:, direction:}]
    @last_known_enemy_pos = nil
    @enemy_predicted_pos = nil
    @items_collected = 0
    @enemy_items_estimate = 0
    @enemy_heatmap = {} # 敵存在確率マップ {coord_key => probability}
    
    # Bug fix: 位置が確定するまでヒートマップは空のまま
    # → diffuse_enemy_probability で位置確定後に初期化される
  end

  # 点対称で敵の初期位置を推定
  # Bug fix: ローカライザーを使用して正しい座標変換を行う
  def estimate_enemy_initial_position
    # 位置が確定している場合のみ推定可能
    return nil unless @localizer&.localized?
    
    # 相対座標を絶対座標に変換してから対称計算
    abs_pos = @localizer.to_absolute(@initial_position)
    return nil unless abs_pos
    
    sym_abs = [SmartChaser::MAP_WIDTH - 1 - abs_pos[0], SmartChaser::MAP_HEIGHT - 1 - abs_pos[1]]
    @localizer.to_relative(sym_abs)
  end

  # グリッドから敵位置を更新
  def update_enemy_tracking(grid)
    return unless grid

    enemy_positions = enemy_positions_from_grid(grid)
    
    if enemy_positions.any?
      update_seen_enemy(enemy_positions)
    else
      update_unseen_enemy(grid)
    end

    # 敵位置の予測を更新
    @enemy_predicted_pos = predict_enemy_position
  end

  # 指定座標の敵存在確率を取得
  def get_enemy_probability(coord)
    @enemy_heatmap[coord_key(coord)]
  end

  # 敵の現在位置を予測（確率が最も高い場所）
  # 敵を一度も目撃していない場合はnilを返す
  def predict_enemy_position
    # 敵を一度も見ていない場合は予測しない（信頼性の低い推測を避ける）
    return nil if @last_known_enemy_pos.nil?

    # 最近目撃している場合はその位置を返す
    if @enemy_sightings.any? && 
       (@turn_count - @enemy_sightings.last[:turn] <= RECENT_SIGHTING_THRESHOLD)
      return @last_known_enemy_pos 
    end
    
    # ヒートマップから最大確率の位置を探す
    max_entry = @enemy_heatmap.max_by { |_, prob| prob }
    return parse_coord_key(max_entry[0]) if max_entry
    
    # ヒートマップも空の場合は最後に見た位置を返す
    @last_known_enemy_pos
  end


  # 敵の移動パターンを分析
  def analyze_enemy_movement_pattern
    return :unknown if @enemy_sightings.size < 3

    # 直近の移動方向を分析
    movements = calculate_recent_movements
    return :unknown if movements.empty?

    # 最も頻繁な移動方向を特定
    identify_dominant_direction(movements)
  end

  # 敵が自分に向かっているかどうか
  def enemy_approaching?
    return false if @enemy_sightings.size < 2

    recent = @enemy_sightings.last(3)
    return false if recent.size < 2

    prev_dist = manhattan_distance(recent.first[:pos], recent.first[:my_pos])
    curr_dist = manhattan_distance(recent.last[:pos], recent.last[:my_pos])

    curr_dist < prev_dist
  end

  # 敵との距離
  def distance_to_enemy
    enemy_pos = predict_enemy_position
    return Float::INFINITY unless enemy_pos
    manhattan_distance(@position, enemy_pos)
  end

  # アイテム収集を記録
  def record_item_collected
    @items_collected += 1
  end

  # 敵のアイテム数を推定（ターン数と探索率から）
  def estimate_enemy_items
    # 簡易推定：自分と同程度のペースと仮定
    return 0 if @turn_count == 0
    rate = @items_collected.to_f / @turn_count
    (@turn_count * rate * ESTIMATED_ITEM_FACTOR).to_i  # 少し控えめに推定
  end

  private

  # 敵が見えている場合の更新処理
  def update_seen_enemy(enemy_positions)
    # 敵が見えている場合：確率を確定
    @last_known_enemy_pos = enemy_positions.first
    record_sighting
    
    # ヒートマップをリセット（観測位置のみ1.0）
    @enemy_heatmap.clear
    enemy_positions.each do |pos|
      @enemy_heatmap[coord_key(pos)] = 1.0
    end
  end

  # 敵が見えていない場合の更新処理
  def update_unseen_enemy(grid)
    # 敵が見えない場合：確率を拡散
    # 視界内の確率は0にする
    clear_visible_area_probability(grid)
    diffuse_enemy_probability
  end

  # 目撃情報の記録
  def record_sighting
    @enemy_sightings << {
      turn: @turn_count,
      pos: @last_known_enemy_pos.dup,
      my_pos: @position.dup
    }
    @enemy_sightings.shift if @enemy_sightings.size > HISTORY_LIMIT
  end

  # 視界内の確率をクリア
  def clear_visible_area_probability(grid)
    SmartChaser::INDEX_TO_OFFSET.each do |index, offset|
      next if grid[index] == SmartChaser::TILE_UNKNOWN # 視界外はクリアしない
      
      coord = [@position[0] + offset[0], @position[1] + offset[1]]
      @enemy_heatmap.delete(coord_key(coord))
    end
  end

  # 敵の存在確率を拡散させる（移動シミュレーション）
  def diffuse_enemy_probability
    # 初期状態（まだ情報がない場合）は点対称位置に確率を置く
    # Bug fix: 初期化後に空のハッシュで上書きしないよう、早期リターン
    if @enemy_heatmap.empty? && @last_known_enemy_pos.nil?
      initialize_probability_at_symmetric_start
      return  # 初期化のみで終了（拡散は次回ターンから）
    end

    new_heatmap = {}

    @enemy_heatmap.each do |key, prob|
      next if prob <= PROBABILITY_THRESHOLD
      distribute_probability_from(key, prob, new_heatmap)
    end
    
    @enemy_heatmap = new_heatmap
  end

  # 初期位置（点対称）に確率を設定
  def initialize_probability_at_symmetric_start
    initial_guess = estimate_enemy_initial_position
    if initial_guess
      @enemy_heatmap[coord_key(initial_guess)] = 1.0
    end
  end

  # 特定のマスから確率を拡散
  def distribute_probability_from(key, prob, new_heatmap)
    current_pos = parse_coord_key(key)
    return unless current_pos
    
    # 移動可能な隣接マス（既知の歩行可能タイルのみ）
    neighbors = get_walkable_neighbors(current_pos)
    
    # その場に留まる確率も含める
    total_options = [neighbors.size + 1, 1].max
    
    # Bug fix: 減衰係数を導入して、古い情報の確率を徐々に下げる
    decay_factor = 0.95
    split_prob = (prob * decay_factor) / total_options
    
    add_probability(new_heatmap, key, split_prob)
    neighbors.each do |n|
      add_probability(new_heatmap, coord_key(n), split_prob)
    end
  end

  # 歩行可能な隣接マスを取得
  # Bug fix: nil（未探索）も通行可能として扱い、確率が未探索エリアに拡散するようにする
  def get_walkable_neighbors(pos)
    neighbors_at(pos).select { |n| 
      tile = @world[coord_key(n)]
      tile.nil? || tile == SmartChaser::TILE_EMPTY || tile == SmartChaser::TILE_ITEM
    }
  end

  # ヒートマップへの確率加算
  def add_probability(heatmap, key, prob)
    heatmap[key] = (heatmap[key] || 0) + prob
  end

  # 直近の移動ベクトルを計算
  def calculate_recent_movements
    movements = []
    @enemy_sightings.each_cons(2) do |prev, curr|
      dx = curr[:pos][0] - prev[:pos][0]
      dy = curr[:pos][1] - prev[:pos][1]
      movements << [dx, dy] if dx != 0 || dy != 0
    end
    movements
  end

  # 主要な移動方向を特定
  def identify_dominant_direction(movements)
    most_common = movements.group_by { |m| m }.max_by { |_, v| v.size }
    return :unknown unless most_common

    dx, dy = most_common.first
    determine_direction_symbol(dx, dy)
  end

  # ベクトルから方向シンボルへ変換
  def determine_direction_symbol(dx, dy)
    case [dx <=> 0, dy <=> 0]
    when [0, -1] then :moving_up
    when [0, 1] then :moving_down
    when [-1, 0] then :moving_left
    when [1, 0] then :moving_right
    when [1, -1] then :moving_up_right
    when [-1, -1] then :moving_up_left
    when [1, 1] then :moving_down_right
    when [-1, 1] then :moving_down_left
    else :unknown
    end
  end
end

class SmartChaser
  include EnemyTrackerBehavior
end
