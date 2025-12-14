class SmartChaser
  def render_world_map(half_step = @move_count * 2)
    bounds = world_bounds
    return unless bounds

    min_x, max_x, min_y, max_y = bounds
    
    # 基本ヘッダー
    header = "[手=#{SmartChaser.format_half_step(half_step)} 位置=#{@position.inspect}]"
    
    # デバッグ情報を追加
    debug_info = build_debug_info
    header += " #{debug_info}" if debug_info

    descriptor_rows = (min_y..max_y).map do |y|
      (min_x..max_x).map { |x| tile_descriptor_for([x, y]) }
    end

    # 推定マップ境界を取得
    est_bounds = nil
    out_bounds = nil
    if @localizer
      est_bounds = @localizer.estimated_bounds
      out_bounds = @localizer.outer_bounds
    end

    # 敵を発見していない場合はヒートマップを表示しない
    heatmap_to_render = @last_known_enemy_pos ? @enemy_heatmap : nil
    render_world_map_gui(bounds, header, descriptor_rows, half_step, heatmap_to_render, est_bounds, out_bounds)
  end

  # ... (build_debug_info is unchanged)

  def render_world_map_gui(bounds, header, descriptor_rows, half_step, heatmap = nil, est_bounds = nil, out_bounds = nil)
    return unless SMART_CHASER_GUI_AVAILABLE
    return if @gui_error

    start_gui_if_available
    return unless @map_renderer
    return if @map_renderer.closed?

    @map_renderer.render(bounds, header, descriptor_rows, half_step, heatmap, est_bounds, out_bounds)
  rescue StandardError => e
    @gui_error = true
    log_map_line("[map] GUI rendering disabled: #{e.class}: #{e.message}")
  end

  def start_gui_if_available
    return unless SMART_CHASER_GUI_AVAILABLE
    return if @gui_error
    return if @map_renderer

    @map_renderer = MapRenderer.new
  rescue StandardError => e
    @map_renderer = nil
    @gui_error = true
    message = "[map] GUI initialization failed: #{e.class}: #{e.message}"
    warn message
    log_map_line(message)
  end

  def wait_for_gui_close_if_needed
    return unless SMART_CHASER_GUI_AVAILABLE
    renderer = @map_renderer
    return unless renderer
    return if renderer.closed?

    renderer.wait_until_closed
  rescue StandardError
    nil
  end

  def log_map_line(str)
    encoding = STDERR.external_encoding
    if encoding
      STDERR.puts(str.encode(encoding, invalid: :replace, undef: :replace))
    else
      STDERR.puts(str)
    end
  rescue Encoding::UndefinedConversionError
    STDERR.puts(str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace))
  end

  def world_bounds
    coords = @world.keys.map { |key| parse_coord_key(key) }.compact
    coords << @position if @position
    return nil if coords.empty?

    xs = coords.map(&:first)
    ys = coords.map(&:last)
    margin = 1
    [
      xs.min - margin,
      xs.max + margin,
      ys.min - margin,
      ys.max + margin
    ]
  end

  def tile_descriptor_for(coord)
    return :self if coord == @position

    status = trap_status(coord)
    # confirmed_safe は通常タイルとして表示（ラベンダー色にしない）
    if status && TRAP_DESCRIPTORS.include?(status) && status != :confirmed_safe
      return status
    end

    key = coord_key(coord)
    return :suspected_trap if @trap_tiles.include?(key)

    tile = @world[key]
    case tile
    when TILE_EMPTY
      :empty
    when TILE_BLOCK
      :block
    when TILE_ITEM
      :item
    when TILE_CHARACTER
      :character
    when TILE_UNKNOWN
      :unknown
    when nil
      :unknown
    else
      :unknown
    end
  end

  def build_debug_info
    strategy_str = case @current_strategy
                   when :aggressive then '攻撃重視'
                   when :defensive then '守備重視'
                   when :item_collection then 'アイテム集中'
                   when :exploration then '探索重視'
                   else 'バランス'
                   end

    item_count = @items_collected || 0
    
    enemy_dist = '-'
    # 簡易的な敵距離計算（視界内の敵のみ）
    if @last_grid
      enemy_indices = @last_grid.each_index.select { |i| @last_grid[i] == TILE_CHARACTER }
      unless enemy_indices.empty?
        enemy_coords = enemy_indices.filter_map { |i| coordinate_from_index(i) }
        unless enemy_coords.empty?
          min_dist = enemy_coords.map { |coord| manhattan_distance(@position, coord) }.min
          enemy_dist = min_dist.to_s
        end
      end
    end

    decision_str = '-'
    if @last_decision
      action = @last_decision[:action]
      verb = action ? action[:verb] : nil
      dir = action ? action[:direction] : nil
      reason = @last_decision[:reason]
      decision_str = "#{verb}(#{dir}): #{reason}" if verb && dir
    end

    # ローカライゼーション状態
    loc_str = '-'
    if @localizer
      if @localizer.localized?
        loc_str = '確定'
      else
        loc_str = "候補#{@localizer.candidates_count}"
      end
    end

    "戦略:#{strategy_str} | アイテム:#{item_count} | 敵距離:#{enemy_dist} | 位置:#{loc_str} | 決定:#{decision_str}"
  end

  # 座標インデックスから座標への変換ヘルパー（rendering用）
  def coordinate_from_index(index)
    offset = INDEX_TO_OFFSET[index]
    return nil unless offset
    [@position[0] + offset[0], @position[1] + offset[1]]
  end
end
