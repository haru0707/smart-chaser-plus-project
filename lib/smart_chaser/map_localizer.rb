# -*- coding: utf-8 -*-
# マップ自己位置推定モジュール（Probabilistic Hypothesis Localization）
# スポーン位置がランダムのため、観測情報から真の絶対座標を特定する
#
# 改良版アルゴリズム:
# 1. 確率的スコアリング: 各候補にスコアを維持し、複数証拠を統合
# 2. 独立軸推定: X軸とY軸を独立に推定（片軸だけ確定も可能）
# 3. 整合性検証: 複数の独立した証拠が同じ結論を支持するか確認
# 4. 段階的確定: 一軸ずつ確定、最終的にoriginを特定
# 5. 事後検証: ロック後も新しい観測で矛盾がないか監視

class SmartChaser
  # MapLocalizer: 確率的仮説推定による自己位置推定
  class MapLocalizer
    attr_reader :possible_origins, :confirmed_origin

    # 確定に必要な最小スコア（複数証拠の一致が必要）
    LOCK_THRESHOLD_SINGLE_AXIS = 2.0   # 片軸確定に必要なスコア
    LOCK_THRESHOLD_CORNER = 3.0        # コーナー確定に必要なスコア
    MIN_OBSERVATIONS_FOR_SOFT_LOCK = 30 # ソフトロック開始の最小観測数

    def initialize(map_width, map_height)
      @map_width = map_width
      @map_height = map_height
      @possible_origins = generate_all_origins
      @confirmed_origin = nil
      @observations = {}  # {relative_coord_key => tile_type}
      @debug = ENV['SMART_CHASER_DEBUG']
      @on_localized = nil

      # 確率的スコアリング用
      @origin_scores = Hash.new(0.0)  # {[ox, oy] => score}
      @axis_x_scores = Hash.new(0.0)  # {ox => score}
      @axis_y_scores = Hash.new(0.0)  # {oy => score}
      @confirmed_x = nil              # X軸が確定した場合の値
      @confirmed_y = nil              # Y軸が確定した場合の値
      @evidence_log = []              # 証拠履歴（デバッグ/検証用）
      @wall_boundary_votes = Hash.new { |h, k| h[k] = { left: 0, right: 0, up: 0, down: 0 } }
    end

    def set_on_localized(&block)
      @on_localized = block
    end

    # 全ての可能な開始位置候補を生成
    def generate_all_origins
      origins = []
      (0...@map_width).each do |x|
        (0...@map_height).each do |y|
          origins << [x, y]
        end
      end
      origins
    end

    # 位置が確定したか
    def localized?
      @confirmed_origin || @possible_origins.size == 1
    end

    # 確定した開始位置（またはnil）
    def origin
      @confirmed_origin || (@possible_origins.size == 1 ? @possible_origins.first : nil)
    end

    # 観測情報で候補を更新
    # relative_tiles: Array of {rel_coord: [rx, ry], tile: type}
    def update(relative_tiles)
      # 事後検証: 確定後も新しい観測で矛盾がないか監視
      if localized?
        relative_tiles.each do |obs|
          rel_coord = obs[:rel_coord]
          tile = obs[:tile]
          next unless rel_coord && tile

          key = "#{rel_coord[0]},#{rel_coord[1]}"
          @observations[key] = tile

          post_localization_verification(rel_coord, tile)
        end
        return
      end

      # Phase 1: ハードプルーニング（確実な除外）
      relative_tiles.each do |obs|
        rel_coord = obs[:rel_coord]
        tile = obs[:tile]
        next unless rel_coord && tile

        key = "#{rel_coord[0]},#{rel_coord[1]}"
        @observations[key] = tile

        # 「通れる場所」のみをプルーニングに使用（ブロックは無視）
        next if tile == TILE_BLOCK
        next if tile == TILE_UNKNOWN

        # 床/アイテム/敵が見えた場合、その絶対座標はマップ内でなければならない
        @possible_origins.reject! do |origin|
          ax = origin[0] + rel_coord[0]
          ay = origin[1] + rel_coord[1]
          out_of_map?(ax, ay)
        end
      end

      # Phase 2: 軸ごとの独立推定（片軸確定の試行）
      apply_axis_constraints

      # Phase 3: ブロック情報による確率的スコアリング
      all_walls = @observations.select { |_, v| v == TILE_BLOCK }.map do |k, v|
        rx, ry = k.split(',').map(&:to_i)
        { rel_coord: [rx, ry], tile: TILE_BLOCK }
      end
      apply_wall_soft_constraint(all_walls)

      # Phase 4: 最終的な位置確定チェック
      check_localization
      reset_if_contradiction
    end

    # 軸ごとの独立した制約適用
    # X軸とY軸を別々に推定し、片方だけでも確定できれば候補を大幅に削減
    def apply_axis_constraints
      return if localized?

      # 現在の候補から可能なX座標とY座標の集合を抽出
      possible_xs = @possible_origins.map { |o| o[0] }.uniq
      possible_ys = @possible_origins.map { |o| o[1] }.uniq

      # X軸が未確定で、候補が1つしかない場合は確定
      if @confirmed_x.nil? && possible_xs.size == 1
        @confirmed_x = possible_xs.first
        log_debug("X-axis confirmed by hard constraint: ox=#{@confirmed_x}")
        add_evidence(:x_axis_hard, @confirmed_x, 10.0)
      end

      # Y軸が未確定で、候補が1つしかない場合は確定
      if @confirmed_y.nil? && possible_ys.size == 1
        @confirmed_y = possible_ys.first
        log_debug("Y-axis confirmed by hard constraint: oy=#{@confirmed_y}")
        add_evidence(:y_axis_hard, @confirmed_y, 10.0)
      end

      # 両軸が確定したらoriginを確定
      if @confirmed_x && @confirmed_y && !@confirmed_origin
        @confirmed_origin = [@confirmed_x, @confirmed_y]
        @possible_origins = [[@confirmed_x, @confirmed_y]]
        log_debug("Origin confirmed by axis intersection: #{@confirmed_origin.inspect}")
      end
    end

    # 証拠を記録（デバッグ/検証用）
    def add_evidence(type, value, score)
      @evidence_log << {
        type: type,
        value: value,
        score: score,
        observation_count: @observations.size,
        candidates: @possible_origins.size
      }
    end

    # 座標がマップ外かどうか
    def out_of_map?(ax, ay)
      ax < 0 || ax >= @map_width || ay < 0 || ay >= @map_height
    end

    # 位置確定チェック
    def check_localization
      if @possible_origins.size == 1
        @confirmed_origin = @possible_origins.first
        log_debug("Localized! Origin confirmed at #{@confirmed_origin.inspect}")
        
        unless @localization_handled
          @localization_handled = true
          @on_localized&.call
        end
      elsif @possible_origins.empty?
        # 全候補が消えた場合はエラー（本来あり得ない）
        log_debug("ERROR: All origin candidates eliminated! Resetting...")
        @possible_origins = generate_all_origins
      end
    end

    # 相対座標から絶対座標を計算（確定時のみ有効）
    def to_absolute(rel_coord)
      return nil unless origin && rel_coord
      [origin[0] + rel_coord[0], origin[1] + rel_coord[1]]
    end

    # 絶対座標から相対座標を計算
    def to_relative(abs_coord)
      return nil unless origin && abs_coord
      [abs_coord[0] - origin[0], abs_coord[1] - origin[1]]
    end

    # 推定されたマップ境界（相対座標系）を返す
    # 全候補で共通する境界のみを確定境界とする
    def estimated_bounds
      return nil if @possible_origins.empty?

      # 各候補について、相対座標系での有効範囲を計算
      # マップ端は絶対座標(0,0)から(w-1,h-1)
      # 相対座標系では origin を引いた値

      min_x_rel = @possible_origins.map { |o| 0 - o[0] }.max
      max_x_rel = @possible_origins.map { |o| (@map_width - 1) - o[0] }.min
      min_y_rel = @possible_origins.map { |o| 0 - o[1] }.max
      max_y_rel = @possible_origins.map { |o| (@map_height - 1) - o[1] }.min

      {
        min_x: min_x_rel,
        max_x: max_x_rel,
        min_y: min_y_rel,
        max_y: max_y_rel,
        candidates_count: @possible_origins.size,
        localized: localized?
      }
    end

    # 相対座標が確実にマップ内かどうか（全候補でマップ内なら真）
    def definitely_inside?(rel_coord)
      return false unless rel_coord
      @possible_origins.all? do |origin|
        ax = origin[0] + rel_coord[0]
        ay = origin[1] + rel_coord[1]
        !out_of_map?(ax, ay)
      end
    end

    # 相対座標が確実にマップ外かどうか（全候補でマップ外なら真）
    def definitely_outside?(rel_coord)
      return false unless rel_coord
      @possible_origins.all? do |origin|
        ax = origin[0] + rel_coord[0]
        ay = origin[1] + rel_coord[1]
        out_of_map?(ax, ay)
      end
    end

    # マップが存在する可能性のある最大範囲（相対座標系）
    # Union of all candidates
    def outer_bounds
      return nil if @possible_origins.empty?

      min_x_rel = @possible_origins.map { |o| 0 - o[0] }.min
      max_x_rel = @possible_origins.map { |o| (@map_width - 1) - o[0] }.max
      min_y_rel = @possible_origins.map { |o| 0 - o[1] }.min
      max_y_rel = @possible_origins.map { |o| (@map_height - 1) - o[1] }.max

      {
        min_x: min_x_rel,
        max_x: max_x_rel,
        min_y: min_y_rel,
        max_y: max_y_rel
      }
    end

    # 候補数を返す（デバッグ用）
    def candidates_count
      @possible_origins.size
    end

    # 壁情報を使ったソフト制約（確率的スコアリング）
    # 複数の独立した証拠を統合し、スコアが閾値を超えた場合のみロック
    def apply_wall_soft_constraint(wall_observations)
      return if localized?
      return if @possible_origins.size <= 1
      return if wall_observations.empty?

      all_walls = wall_observations.map { |w| w[:rel_coord] }

      # ============================================================
      # Step 1: 対面壁による確定的ロック（最も信頼性が高い）
      # 両端の壁が見えた場合、幾何学的に一意に確定可能
      # ============================================================
      if check_opposing_walls_verified(all_walls)
        return if localized?
      end

      # ============================================================
      # Step 2: 境界壁候補のスコアリング
      # 各壁ブロックが「どの境界に属するか」の仮説をスコアリング
      # ============================================================
      score_boundary_hypotheses(all_walls)

      # ============================================================
      # Step 3: 軸ごとの確定チェック（スコアベース）
      # 十分なスコアが蓄積された軸のみ確定
      # ============================================================
      try_axis_lock_by_score

      # ============================================================
      # Step 4: コーナー検出による相互検証
      # 2方向の壁が同時に見えた場合、両方の証拠が一致するか検証
      # ============================================================
      wall_runs = detect_wall_runs(wall_observations)
      check_corner_with_verification(wall_runs)
    end

    # 各壁ブロックが境界に属する場合のorigin候補をスコアリング
    def score_boundary_hypotheses(all_walls)
      return if all_walls.empty?

      all_walls.each do |wall_coord|
        rx, ry = wall_coord

        # この壁が左境界(x=-1)に属する場合: origin_x = -1 - rx
        # この壁が右境界(x=W)に属する場合: origin_x = W - rx
        # この壁が上境界(y=-1)に属する場合: origin_y = -1 - ry
        # この壁が下境界(y=H)に属する場合: origin_y = H - ry

        candidate_ox_left = -1 - rx
        candidate_ox_right = @map_width - rx
        candidate_oy_up = -1 - ry
        candidate_oy_down = @map_height - ry

        # 距離による重み付け（遠い壁ほど信頼性が高い）
        # 視界内の壁は距離1-9程度、境界壁は距離が大きい傾向
        distance = [rx.abs, ry.abs].max
        weight = 0.1 + (distance * 0.05)  # 距離が大きいほど重み増加

        # 有効なorigin範囲内の候補のみスコアを加算
        if candidate_ox_left >= 0 && candidate_ox_left < @map_width
          @axis_x_scores[candidate_ox_left] += weight
        end
        if candidate_ox_right >= 0 && candidate_ox_right < @map_width
          @axis_x_scores[candidate_ox_right] += weight
        end
        if candidate_oy_up >= 0 && candidate_oy_up < @map_height
          @axis_y_scores[candidate_oy_up] += weight
        end
        if candidate_oy_down >= 0 && candidate_oy_down < @map_height
          @axis_y_scores[candidate_oy_down] += weight
        end
      end
    end

    # スコアに基づく軸の確定
    def try_axis_lock_by_score
      return if localized?
      return if @observations.size < MIN_OBSERVATIONS_FOR_SOFT_LOCK

      # 現在の候補で可能なorigin値のみを対象とする
      possible_xs = @possible_origins.map { |o| o[0] }.uniq
      possible_ys = @possible_origins.map { |o| o[1] }.uniq

      # X軸のスコアチェック
      if @confirmed_x.nil? && possible_xs.size > 1
        x_scores = possible_xs.map { |x| [x, @axis_x_scores[x]] }.to_h
        max_x_score = x_scores.values.max || 0
        second_x_score = x_scores.values.sort.reverse[1] || 0

        # 最高スコアが閾値を超え、かつ2位との差が十分ある場合のみ確定
        if max_x_score >= LOCK_THRESHOLD_SINGLE_AXIS && max_x_score - second_x_score >= 1.0
          best_x = x_scores.key(max_x_score)
          @confirmed_x = best_x
          @possible_origins.select! { |o| o[0] == best_x }
          log_debug("X-axis locked by score: ox=#{best_x} (score=#{max_x_score}, 2nd=#{second_x_score})")
          add_evidence(:x_axis_score, best_x, max_x_score)
        end
      end

      # Y軸のスコアチェック
      if @confirmed_y.nil? && possible_ys.size > 1
        y_scores = possible_ys.map { |y| [y, @axis_y_scores[y]] }.to_h
        max_y_score = y_scores.values.max || 0
        second_y_score = y_scores.values.sort.reverse[1] || 0

        if max_y_score >= LOCK_THRESHOLD_SINGLE_AXIS && max_y_score - second_y_score >= 1.0
          best_y = y_scores.key(max_y_score)
          @confirmed_y = best_y
          @possible_origins.select! { |o| o[1] == best_y }
          log_debug("Y-axis locked by score: oy=#{best_y} (score=#{max_y_score}, 2nd=#{second_y_score})")
          add_evidence(:y_axis_score, best_y, max_y_score)
        end
      end

      # 両軸確定でorigin確定
      if @confirmed_x && @confirmed_y && !@confirmed_origin
        @confirmed_origin = [@confirmed_x, @confirmed_y]
        @possible_origins = [[@confirmed_x, @confirmed_y]]
        log_debug("Origin confirmed by axis scores: #{@confirmed_origin.inspect}")
      end
    end

    # 対面壁によるロック（検証付き堅牢版）
    # 両端の壁が見えた場合、幾何学的に一意に確定可能
    # 追加検証: 対面壁間の距離がマップサイズと一致することを確認
    def check_opposing_walls_verified(all_walls)
      return false if all_walls.empty?

      x_locked = false
      y_locked = false

      # X軸チェック（左右の境界壁）
      x_coords = all_walls.map { |c| c[0] }
      min_x = x_coords.min
      max_x = x_coords.max
      dist_x = max_x - min_x

      if dist_x == @map_width + 1
        # 追加検証: 左端と右端の両方に複数のブロックがあるか確認
        left_walls = all_walls.select { |c| c[0] == min_x }
        right_walls = all_walls.select { |c| c[0] == max_x }

        # 両端にそれぞれ最低1つのブロックがあれば確定
        if left_walls.size >= 1 && right_walls.size >= 1
          # さらなる検証: この距離が偶然の一致でないか
          # 間に床/アイテムの観測があれば、それらがマップ内に収まるか確認
          target_origin_x = -1 - min_x

          if target_origin_x >= 0 && target_origin_x < @map_width
            # 中間の観測がこのorigin_xと整合するか検証
            if verify_observations_consistency_x(target_origin_x)
              @confirmed_x = target_origin_x
              @possible_origins.select! { |o| o[0] == target_origin_x }
              log_debug("X-axis locked by opposing walls: ox=#{target_origin_x} (dist=#{dist_x}, left=#{left_walls.size}, right=#{right_walls.size})")
              add_evidence(:opposing_walls_x, target_origin_x, 5.0)
              x_locked = true
            end
          end
        end
      end

      # Y軸チェック（上下の境界壁）
      y_coords = all_walls.map { |c| c[1] }
      min_y = y_coords.min
      max_y = y_coords.max
      dist_y = max_y - min_y

      if dist_y == @map_height + 1
        top_walls = all_walls.select { |c| c[1] == min_y }
        bottom_walls = all_walls.select { |c| c[1] == max_y }

        if top_walls.size >= 1 && bottom_walls.size >= 1
          target_origin_y = -1 - min_y

          if target_origin_y >= 0 && target_origin_y < @map_height
            if verify_observations_consistency_y(target_origin_y)
              @confirmed_y = target_origin_y
              @possible_origins.select! { |o| o[1] == target_origin_y }
              log_debug("Y-axis locked by opposing walls: oy=#{target_origin_y} (dist=#{dist_y}, top=#{top_walls.size}, bottom=#{bottom_walls.size})")
              add_evidence(:opposing_walls_y, target_origin_y, 5.0)
              y_locked = true
            end
          end
        end
      end

      # 両軸確定でorigin確定
      if @confirmed_x && @confirmed_y && !@confirmed_origin
        @confirmed_origin = [@confirmed_x, @confirmed_y]
        @possible_origins = [[@confirmed_x, @confirmed_y]]
        log_debug("Origin confirmed by opposing walls: #{@confirmed_origin.inspect}")
      end

      check_localization
      x_locked || y_locked
    end

    # X軸の整合性検証: このorigin_xで全ての観測が矛盾しないか
    def verify_observations_consistency_x(origin_x)
      @observations.each do |key, tile|
        rx, ry = key.split(',').map(&:to_i)
        ax = origin_x + rx

        # 床/アイテムはマップ内に、壁はマップ外にあるべき
        if tile == TILE_BLOCK
          # 壁がマップ内にある場合も許可（内部ブロック）
          # ただし、境界壁と矛盾する場合は不整合
          next
        else
          # 床/アイテム/敵はマップ内(0..W-1)でなければならない
          return false if ax < 0 || ax >= @map_width
        end
      end
      true
    end

    # Y軸の整合性検証
    def verify_observations_consistency_y(origin_y)
      @observations.each do |key, tile|
        rx, ry = key.split(',').map(&:to_i)
        ay = origin_y + ry

        if tile == TILE_BLOCK
          next
        else
          return false if ay < 0 || ay >= @map_height
        end
      end
      true
    end

    # 後方互換性のためのエイリアス
    def check_opposing_walls_robust(all_walls)
      check_opposing_walls_verified(all_walls)
    end

    # コーナー検出による相互検証（改良版）
    # 2方向の壁が見えた場合、両方の証拠が一致するか検証してからロック
    def check_corner_with_verification(runs)
      return if localized?

      # 各コーナーをチェック（左上、右上、左下、右下）
      corner_candidates = []

      # 左上コーナー: 左壁(x < 0) と 上壁(y < 0)
      corner_candidates << check_corner_verified(runs, :left, :up)
      # 右上コーナー: 右壁(x > 0) と 上壁(y < 0)
      corner_candidates << check_corner_verified(runs, :right, :up)
      # 左下コーナー: 左壁(x < 0) と 下壁(y > 0)
      corner_candidates << check_corner_verified(runs, :left, :down)
      # 右下コーナー: 右壁(x > 0) と 下壁(y > 0)
      corner_candidates << check_corner_verified(runs, :right, :down)

      corner_candidates.compact!
      return if corner_candidates.empty?

      # 複数のコーナー候補がある場合、スコアが最も高いものを選択
      best_corner = corner_candidates.max_by { |c| c[:score] }
      return unless best_corner

      # スコアが閾値を超えていて、候補として有効な場合のみロック
      if best_corner[:score] >= LOCK_THRESHOLD_CORNER
        est_origin = best_corner[:origin]

        if @possible_origins.include?(est_origin)
          # 追加検証: この候補で全ての観測が整合するか
          if verify_full_consistency(est_origin)
            @confirmed_origin = est_origin
            @confirmed_x = est_origin[0]
            @confirmed_y = est_origin[1]
            @possible_origins = [est_origin]
            log_debug("Corner verified and locked: #{est_origin.inspect} (score=#{best_corner[:score]}, h=#{best_corner[:h_dir]}, v=#{best_corner[:v_dir]})")
            add_evidence(:corner_verified, est_origin, best_corner[:score])
            check_localization
          end
        end
      end
    end

    # 単一コーナーの検証
    def check_corner_verified(runs, h_dir, v_dir)
      # 対応する方向の壁ラインを探す
      h_runs = runs.select { |r| r[:direction] == h_dir }
      v_runs = runs.select { |r| r[:direction] == v_dir }

      return nil if h_runs.empty? || v_runs.empty?

      # 最も外側（境界壁の可能性が高い）の壁を選択
      h_run = h_runs.min_by { |r| h_dir == :left ? r[:coords].first[0] : -r[:coords].first[0] }
      v_run = v_runs.min_by { |r| v_dir == :up ? r[:coords].first[1] : -r[:coords].first[1] }

      return nil unless h_run && v_run

      # 壁の長さに基づくスコア計算
      h_score = h_run[:length] * 0.5
      v_score = v_run[:length] * 0.5

      # 壁の座標から推定originを計算
      hx = h_run[:coords].first[0]
      vy = v_run[:coords].first[1]

      # 境界座標の決定
      target_bound_x = (h_dir == :left) ? -1 : @map_width
      target_bound_y = (v_dir == :up) ? -1 : @map_height

      est_origin_x = target_bound_x - hx
      est_origin_y = target_bound_y - vy

      # 有効範囲チェック
      return nil unless est_origin_x >= 0 && est_origin_x < @map_width
      return nil unless est_origin_y >= 0 && est_origin_y < @map_height

      # 追加スコア: 壁が実際に外側にあるかどうか
      # 左壁は負のX座標、右壁は正のX座標であるべき
      h_direction_valid = (h_dir == :left && hx < 0) || (h_dir == :right && hx > 0)
      v_direction_valid = (v_dir == :up && vy < 0) || (v_dir == :down && vy > 0)

      # 方向が正しくない場合はスコアを大幅に減らす
      h_score *= 0.3 unless h_direction_valid
      v_score *= 0.3 unless v_direction_valid

      total_score = h_score + v_score

      # 両方の壁が長さ2以上の場合はボーナス
      if h_run[:length] >= 2 && v_run[:length] >= 2
        total_score += 1.0
      end

      # 両方の壁が長さ3以上の場合はさらにボーナス
      if h_run[:length] >= 3 && v_run[:length] >= 3
        total_score += 1.0
      end

      {
        origin: [est_origin_x, est_origin_y],
        score: total_score,
        h_dir: h_dir,
        v_dir: v_dir,
        h_length: h_run[:length],
        v_length: v_run[:length]
      }
    end

    # 完全な整合性検証: この候補originで全ての観測が矛盾しないか
    def verify_full_consistency(origin)
      ox, oy = origin

      @observations.each do |key, tile|
        rx, ry = key.split(',').map(&:to_i)
        ax = ox + rx
        ay = oy + ry

        if tile == TILE_BLOCK
          # ブロックは境界外(-1, W, H等)または内部のどこでもOK
          next
        else
          # 床/アイテム/敵はマップ内でなければならない
          return false if ax < 0 || ax >= @map_width || ay < 0 || ay >= @map_height
        end
      end
      true
    end

    # 後方互換性のためのエイリアス
    def check_corner_constraints_relaxed(runs)
      check_corner_with_verification(runs)
    end

    def check_corner_relaxed(runs, h_dir, v_dir, corner_x, corner_y)
      # 新しいメソッドに委譲（個別呼び出しは不要だが互換性のため残す）
      nil
    end

    # その候補位置において、検出された壁列がマップ境界と一致するか
    def is_boundary_consistent?(origin, run)
      # 壁列の最初の座標を絶対座標に変換
      rel_start = run[:coords].first
      abs_start_x = origin[0] + rel_start[0]
      abs_start_y = origin[1] + rel_start[1]
      
      case run[:direction]
      when :up
        # 上方向の壁列 → 上端(y=-1) または 下端(y=H) ?
        # ここでは「視界内で連続する壁」なので、それがマップ境界線そのものであるか判定
        # Y座標が -1 (上端外) または H (下端外) であれば境界壁
        # ただし、SmartChaserの座標系は 0..W-1, 0..H-1 がマップ内
        # 壁として見えるのは、マップ外の座標 (-1, H, etc)
        
        # 連続する壁のY座標がすべて一致しているはず
        # 壁のY座標が -1 (上) または H (下) なら境界
        abs_start_y == -1 || abs_start_y == @map_height
      when :down
        abs_start_y == -1 || abs_start_y == @map_height
      when :left
        # 左端(-1) または 右端(W)
        abs_start_x == -1 || abs_start_x == @map_width
      when :right
        abs_start_x == -1 || abs_start_x == @map_width
      else
        false
      end
    end

    # 矛盾時のリセット（安全装置）
    # 改良版: より詳細な矛盾検出と部分リセット
    def reset_if_contradiction
      if @possible_origins.empty?
        log_debug("WARNING: Contradiction detected! All candidates eliminated.")
        log_debug("Evidence log: #{@evidence_log.last(5).inspect}")

        # 矛盾の原因を分析（デバッグ用）
        if @confirmed_origin
          log_debug("Contradiction with confirmed origin: #{@confirmed_origin.inspect}")
        end
        if @confirmed_x
          log_debug("Confirmed X was: #{@confirmed_x}")
        end
        if @confirmed_y
          log_debug("Confirmed Y was: #{@confirmed_y}")
        end

        # 完全リセット
        @possible_origins = generate_all_origins
        @confirmed_origin = nil
        @confirmed_x = nil
        @confirmed_y = nil
        @origin_scores = Hash.new(0.0)
        @axis_x_scores = Hash.new(0.0)
        @axis_y_scores = Hash.new(0.0)
        @evidence_log = []

        # 観測データは保持（ハードプルーニングを再適用）
        preserved_observations = @observations.dup
        @observations = {}
        @localization_handled = false

        # 保持した観測データを再適用
        reapply_observations(preserved_observations)
      end
    end

    # 観測データの再適用
    def reapply_observations(preserved_observations)
      preserved_observations.each do |key, tile|
        rx, ry = key.split(',').map(&:to_i)

        # 観測を再登録
        @observations[key] = tile

        # ハードプルーニングのみ再適用（ソフト制約は後で）
        next if tile == TILE_BLOCK
        next if tile == TILE_UNKNOWN

        @possible_origins.reject! do |origin|
          ax = origin[0] + rx
          ay = origin[1] + ry
          out_of_map?(ax, ay)
        end
      end

      log_debug("Reapplied #{preserved_observations.size} observations, #{@possible_origins.size} candidates remain")
    end

    # 事後検証: 確定後も新しい観測で矛盾がないか監視
    # localized?がtrueでも呼び出される
    def post_localization_verification(rel_coord, tile)
      return unless @confirmed_origin
      return if tile == TILE_BLOCK  # ブロックは内部/外部の両方がありえる
      return if tile == TILE_UNKNOWN

      ax = @confirmed_origin[0] + rel_coord[0]
      ay = @confirmed_origin[1] + rel_coord[1]

      if out_of_map?(ax, ay)
        log_debug("POST-LOCK CONTRADICTION: Tile #{tile} at relative #{rel_coord.inspect} -> absolute #{[ax, ay].inspect} is out of map!")
        log_debug("This indicates a localization error. Consider resetting.")

        # 矛盾を検出したが、即座にリセットはしない
        # 代わりに、信頼度を下げて監視を続ける
        @contradiction_count ||= 0
        @contradiction_count += 1

        # 複数回の矛盾でリセット
        if @contradiction_count >= 3
          log_debug("Multiple contradictions detected. Forcing reset.")
          @possible_origins = []
          reset_if_contradiction
        end
      end
    end

    # 壁のライン検出（改良版）
    # 不連続でも軸が一致していれば同一ラインとみなす
    # 方向判定を改善: 座標の符号だけでなく、候補との整合性も考慮
    def detect_wall_runs(wall_observations)
      runs = []
      coords = wall_observations.map { |w| w[:rel_coord] }

      # 垂直ラインの検出 (同一X座標)
      x_groups = coords.group_by { |x, y| x }
      x_groups.each do |x, group|
        next if group.size < 2 # 2ブロック以上でラインとみなす

        # 改良された方向判定
        # 基本: 負のXは左方向、正のXは右方向
        # ただし、X=0は曖昧なので両方向の可能性を考慮
        if x < 0
          dir = :left
        elsif x > 0
          dir = :right
        else
          # X=0の場合: 候補の分布から推定
          # 左境界(x=-1)に対応するorigin_x = 1 が候補にあれば :left
          # 右境界(x=W)に対応するorigin_x = W-1 = 14 が候補にあれば :right
          left_possible = @possible_origins.any? { |o| o[0] == 1 }
          right_possible = @possible_origins.any? { |o| o[0] == @map_width - 1 }

          if left_possible && !right_possible
            dir = :left
          elsif right_possible && !left_possible
            dir = :right
          else
            # 両方可能または両方不可能な場合は、より外側の可能性を優先
            dir = :left  # デフォルトは左（後でスコアで調整）
          end
        end

        sorted_coords = group.sort_by { |_, y| y }
        runs << { direction: dir, length: group.size, coords: sorted_coords, x: x }
      end

      # 水平ラインの検出 (同一Y座標)
      y_groups = coords.group_by { |x, y| y }
      y_groups.each do |y, group|
        next if group.size < 2

        if y < 0
          dir = :up
        elsif y > 0
          dir = :down
        else
          # Y=0の場合: 候補の分布から推定
          up_possible = @possible_origins.any? { |o| o[1] == 1 }
          down_possible = @possible_origins.any? { |o| o[1] == @map_height - 1 }

          if up_possible && !down_possible
            dir = :up
          elsif down_possible && !up_possible
            dir = :down
          else
            dir = :up  # デフォルトは上
          end
        end

        sorted_coords = group.sort_by { |x, _| x }
        runs << { direction: dir, length: group.size, coords: sorted_coords, y: y }
      end

      # 外側の壁を優先するようにソート
      runs.sort_by! do |run|
        coord = run[:coords].first
        case run[:direction]
        when :left  then coord[0]
        when :right then -coord[0]
        when :up    then coord[1]
        when :down  then -coord[1]
        else 0
        end
      end

      runs
    end

    def direction_match?(coord, dir)
      case dir
      when :up then coord[1] < 0
      when :down then coord[1] > 0
      when :left then coord[0] < 0
      when :right then coord[0] > 0
      else false
      end
    end

    def distance_in_direction(coord, dir)
      case dir
      when :up, :down then coord[1].abs
      when :left, :right then coord[0].abs
      else 0
      end
    end

    def adjacent_in_direction?(a, b, dir)
      case dir
      when :up, :down then a[0] == b[0] && (a[1] - b[1]).abs == 1
      when :left, :right then a[1] == b[1] && (a[0] - b[0]).abs == 1
      else false
      end
    end

    # 探索フェーズ判定（探索率に基づく）
    # @exploration_ratio が高い → まだ探索が進んでいない（序盤）
    def exploration_phase?
      # 観測したタイル数が少なければ序盤
      @observations.size < 50
    end

    # 位置特定に最も寄与するSearch方向を返す
    # 候補の分散が大きい方向を優先
    def best_search_direction
      return nil if localized?

      bounds = estimated_bounds
      return nil unless bounds

      # 各方向の「不確定範囲」を計算
      x_uncertainty = (bounds[:max_x] - bounds[:min_x]).abs
      y_uncertainty = (bounds[:max_y] - bounds[:min_y]).abs

      if x_uncertainty > y_uncertainty
        # X軸の不確定性が高い → 左右を見る
        bounds[:min_x].abs > bounds[:max_x].abs ? :left : :right
      else
        # Y軸の不確定性が高い → 上下を見る
        bounds[:min_y].abs > bounds[:max_y].abs ? :up : :down
      end
    end

    private

    def log_debug(msg)
      STDERR.puts "[localizer] #{msg}" if @debug
    end
  end

  # ============================================================
  # SmartChaser クラスへの統合メソッド
  # ============================================================

  # ローカライザーを初期化
  def init_localizer
    @localizer = MapLocalizer.new(MAP_WIDTH, MAP_HEIGHT)
  end

  # 毎ターンの視界情報でローカライザーを更新
  def update_localizer_with_grid(grid)
    return unless @localizer && grid

    observations = []
    INDEX_TO_OFFSET.each do |index, (dx, dy)|
      tile = grid[index]
      next if tile.nil?

      # 相対座標（現在位置からのオフセット）
      # 注: @position は相対座標系での現在位置
      rel_coord = [@position[0] + dx, @position[1] + dy]
      observations << { rel_coord: rel_coord, tile: tile }
    end

    @localizer.update(observations)
  end

  # ローカライザーが位置を確定したか
  def position_localized?
    @localizer&.localized?
  end

  # 推定マップ境界を取得
  def get_estimated_map_bounds
    @localizer&.estimated_bounds
  end

  # 相対座標が確実にマップ内か
  def definitely_in_map?(rel_coord)
    @localizer&.definitely_inside?(rel_coord)
  end

  # 相対座標が確実にマップ外か
  def definitely_out_of_map?(rel_coord)
    @localizer&.definitely_outside?(rel_coord)
  end

  # 探索フェーズかどうか（序盤はwalk優先、後半はsearch活用）
  def in_exploration_phase?
    @localizer&.exploration_phase? || false
  end

  # 位置特定のためにSearchを使うべきか
  # サーチ削減のため無効化（移動による情報収集を優先）
  def should_use_search_for_localization?(grid)
    # 位置特定のためのサーチは行わない
    false
  end

  # 位置特定に最も効果的なSearch方向を取得
  def get_best_search_direction_for_localization
    @localizer&.best_search_direction
  end
end

