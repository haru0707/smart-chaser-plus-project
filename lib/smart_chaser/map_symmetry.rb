# -*- coding: utf-8 -*-
# マップ対称性・境界検出モジュール
# U-16プロコン北海道大会対応（マップ点対称を活用）

class SmartChaser
  # ============================================================
  # 点対称座標計算
  # ============================================================

  # 点対称座標を計算（中心: [7, 8]）
  # 座標 (x, y) → (14-x, 16-y)
  def symmetric_coord(coord)
    return nil unless coord
    [MAP_WIDTH - 1 - coord[0], MAP_HEIGHT - 1 - coord[1]]
  end

  # 座標がマップ境界外かどうか（ローカライザー対応）
  def out_of_bounds?(coord)
    return true unless coord
    
    # ローカライザーがあれば使用（相対座標系で判定）
    if @localizer
      return @localizer.definitely_outside?(coord)
    end
    
    # フォールバック: 固定マップサイズで判定
    x, y = coord
    x < 0 || x >= MAP_WIDTH || y < 0 || y >= MAP_HEIGHT
  end

  # 座標がマップ端（境界から1マス以内）かどうか
  def is_edge?(coord)
    return false unless coord
    x, y = coord
    x == 0 || x == MAP_WIDTH - 1 || y == 0 || y == MAP_HEIGHT - 1
  end

  # 座標がマップ端付近かどうか（ローカライザー対応）
  def near_edge?(coord)
    return false unless coord
    
    # ローカライザーで推定境界を使用
    if @localizer
      # 探索のために「可能性のある範囲」の端かどうかを判定
      # estimated_bounds (Intersection) を使うと安全圏の端でビビってしまうため、
      # outer_bounds (Union) を使用して「本当にマップ外に近い」場合のみ警告する
      bounds = @localizer.outer_bounds || @localizer.estimated_bounds
      if bounds
        x, y = coord
        return x <= bounds[:min_x] + 1 || x >= bounds[:max_x] - 1 ||
               y <= bounds[:min_y] + 1 || y >= bounds[:max_y] - 1
      end
    end
    
    # フォールバック
    x, y = coord
    x <= 1 || x >= MAP_WIDTH - 2 || y <= 1 || y >= MAP_HEIGHT - 2
  end

  # ============================================================
  # 対称推論
  # ============================================================

  # 対称位置から未知タイルを推論
  # ブロック（壁）のみ対称推論する（アイテムは非対称の可能性あり）
  def infer_tile_from_symmetry(coord)
    return nil unless coord
    return nil if out_of_bounds?(coord)

    sym_coord = symmetric_coord(coord)
    return nil unless sym_coord
    return nil if out_of_bounds?(sym_coord)

    sym_key = coord_key(sym_coord)
    sym_tile = @world[sym_key]
    
    # 自分で置いたブロック（アイテム跡地含む）は対称推論のソースとして使わない
    # これを行わないと、自作ブロックの反対側に「偽の壁（Ghost Wall）」が出現し、
    # A*経路探索がそこを通れないと誤認して無限ループ等の原因になる
    return nil if @self_placed_blocks && @self_placed_blocks.include?(sym_key)
    
    # アイテムのみ対称推論する（ブロックの対称推論は無効化）
    # ルール上、アイテム配置も点対称であるため
    return TILE_ITEM if sym_tile == TILE_ITEM
    
    # 空きタイルは弱い推論（通行可能と仮定）
    return sym_tile if sym_tile == TILE_EMPTY
    
    nil
  end

  # 観測したブロック/アイテムから対称位置を推論してワールドマップに適用
  # 注意: 位置が確定するまで対称推論は行わない（誤推論防止）
  def apply_symmetric_inference(coord, tile)
    # 位置が確定していない場合は対称推論を行わない
    return unless @localizer&.localized?
    # ブロックまたはアイテムのみ推論対象
    return unless coord && (tile == TILE_BLOCK || tile == TILE_ITEM)
    
    # 壁の対称書き込みは無効化（ユーザー要望）
    return if tile == TILE_BLOCK
    
    # 絶対座標に変換して対称位置を計算
    abs_coord = @localizer.to_absolute(coord)
    return unless abs_coord
    
    sym_abs_coord = symmetric_coord_absolute(abs_coord)
    return unless sym_abs_coord
    
    # 相対座標に戻す
    sym_rel_coord = @localizer.to_relative(sym_abs_coord)
    return unless sym_rel_coord
    
    sym_key = coord_key(sym_rel_coord)
    
    # 対称位置が未知の場合のみ推論を適用
    if @world[sym_key].nil?
      @world[sym_key] = tile # 対称タイルの種類（同じ）をセット
      @inferred_symmetric_tiles ||= Set.new
      @inferred_symmetric_tiles.add(sym_key)
      
      # アイテム数の追跡などは別途 update_world_state で行われるため、ここではマップ配置のみ
      
      if ENV['SMART_CHASER_DEBUG']
        type_str = (tile == TILE_BLOCK) ? "BLOCK" : "ITEM"
        STDERR.puts "[symmetry] Inferred #{type_str} at #{sym_rel_coord.inspect} (abs: #{sym_abs_coord.inspect}) from #{coord.inspect}"
      end
    end
  end
  
  # 絶対座標系での点対称座標を計算
  def symmetric_coord_absolute(abs_coord)
    return nil unless abs_coord
    ax, ay = abs_coord
    return nil if ax < 0 || ax >= MAP_WIDTH || ay < 0 || ay >= MAP_HEIGHT
    [MAP_WIDTH - 1 - ax, MAP_HEIGHT - 1 - ay]
  end

  # 座標が「真に未知」かどうか（対称推論でも分からない）
  def is_truly_unknown?(coord)
    return false unless coord
    return false if out_of_bounds?(coord)
    
    key = coord_key(coord)
    return false unless @world[key].nil?
    
    # 対称位置も未知かどうか
    inferred = infer_tile_from_symmetry(coord)
    inferred.nil?
  end

  # ============================================================
  # 境界推定
  # ============================================================

  # 観測データからマップ境界を推定
  # 連続するブロックのパターンを検出
  def update_map_boundary_estimate
    @boundary_estimate ||= {
      min_x: 0,
      max_x: MAP_WIDTH - 1,
      min_y: 0,
      max_y: MAP_HEIGHT - 1,
      confidence: 0.0
    }
    
    # ブロックの分布を分析
    blocks_by_x = Hash.new(0)
    blocks_by_y = Hash.new(0)
    
    @world.each do |key, tile|
      next unless tile == TILE_BLOCK
      coord = parse_coord_key(key)
      next unless coord
      
      blocks_by_x[coord[0]] += 1
      blocks_by_y[coord[1]] += 1
    end
    
    # 端付近にブロックが多いかチェック
    edge_blocks = 0
    [0, 1, MAP_WIDTH - 2, MAP_WIDTH - 1].each { |x| edge_blocks += blocks_by_x[x] }
    [0, 1, MAP_HEIGHT - 2, MAP_HEIGHT - 1].each { |y| edge_blocks += blocks_by_y[y] }
    
    total_blocks = blocks_by_x.values.sum
    if total_blocks > 0
      @boundary_estimate[:confidence] = [edge_blocks.to_f / total_blocks, 1.0].min
    end
  end

  # ============================================================
  # 探索優先度計算
  # ============================================================

  # 探索優先度を計算（高いほど探索価値が高い）
  # 訪問回数を考慮して、何度も訪問した場所からの探索を抑制
  def exploration_priority(coord)
    return -Float::INFINITY unless coord
    return -Float::INFINITY if out_of_bounds?(coord)

    key = coord_key(coord)
    tile = @world[key]

    # 既に探索済みは優先度0
    return 0.0 unless tile.nil?

    priority = 10.0  # 基礎優先度

    # 対称位置が未知の場合は高優先度（2倍の情報価値）
    if is_truly_unknown?(coord)
      priority += 5.0
    end

    # 端付近は低優先度（壁の可能性が高い）
    if near_edge?(coord)
      priority -= 3.0
    end

    # 端そのものは更に低優先度
    if is_edge?(coord)
      priority -= 5.0
    end

    # マップ中心付近は高優先度（探索効率が良い）
    center_dist = manhattan_distance(coord, MAP_CENTER)
    priority -= center_dist * 0.2

    # 隣接マスの未探索度と訪問回数を考慮
    neighbors_at(coord).each do |n|
      n_key = coord_key(n)
      n_tile = @world[n_key]

      if n_tile.nil?
        # 未探索の隣接マスはボーナス
        priority += 0.5
      elsif walkable_tile?(n_tile)
        # 訪問回数が多い隣接マスはペナルティ（そこから来る可能性が高い）
        visit_count = @visit_counts[[n.first, n.last]] || 0
        priority -= visit_count * 0.3
      end
    end

    priority
  end

  # 最も探索優先度が高い未探索座標を返す
  # from座標の訪問回数も考慮して、何度も訪問した場所からの探索を避ける
  def best_frontier_by_priority
    candidates = []

    @world.each do |key, tile|
      next unless walkable_tile?(tile)
      coord = parse_coord_key(key)
      next unless coord

      # from座標（経由地点）の訪問回数を取得
      from_visit_count = @visit_counts[coord] || 0

      # 隣接に未探索タイルがある座標を候補に
      neighbors_at(coord).each do |n|
        next if out_of_bounds?(n)
        next unless @world[coord_key(n)].nil?

        base_priority = exploration_priority(n)

        # from座標の訪問回数に基づくペナルティ
        # 何度も訪問した場所からの探索は優先度を下げる
        from_penalty = from_visit_count * 0.8

        # 現在位置からの距離も考慮（近いほど優先）
        distance_to_from = manhattan_distance(@position, coord)
        distance_penalty = distance_to_from * 0.3

        adjusted_priority = base_priority - from_penalty - distance_penalty

        candidates << { coord: n, from: coord, priority: adjusted_priority }
      end
    end

    return nil if candidates.empty?

    # 優先度順にソートして最高のものを返す
    candidates.max_by { |c| c[:priority] }
  end

  # ============================================================
  # 効率的探索方向選択
  # ============================================================

  # 対称情報を考慮した探索方向選択
  def choose_symmetric_aware_exploration(grid)
    best = nil
    best_score = -Float::INFINITY
    
    DIRECTIONS.each_key do |dir|
      coord = coordinate_in_direction(dir)
      next unless coord
      next if out_of_bounds?(coord)
      next unless front_walkable?(grid, dir)
      next if would_trap_on_move?(dir, grid)
      
      score = 0.0
      
      # その方向の新規タイル数（対称推論を考慮）
      (1..9).each do |dist|
        delta = DIRECTION_DELTAS[dir]
        check_coord = [coord[0] + delta[0] * (dist - 1), coord[1] + delta[1] * (dist - 1)]
        next if out_of_bounds?(check_coord)
        
        if is_truly_unknown?(check_coord)
          score += 2.0  # 真に未知は高価値
        elsif @world[coord_key(check_coord)].nil?
          score += 1.0  # 推論可能な未知は中価値
        end
      end
      
      # 探索優先度を加算
      score += exploration_priority(coord)
      
      # 端方向へのペナルティ
      if near_edge?(coord)
        score -= 2.0
      end
      
      if score > best_score
        best_score = score
        best = dir
      end
    end
    
    best
  end

  # A*探索でフロンティアへ向かう際に対称情報を活用
  def astar_to_frontier_symmetric(enemy_positions = [])
    best = best_frontier_by_priority
    return nil unless best
    
    target_coord = best[:coord]
    from_coord = best[:from]
    
    # from_coord への経路を探索
    astar_first_step(
      ->(pos) { pos == from_coord },
      enemy_positions
    )
  end
end
