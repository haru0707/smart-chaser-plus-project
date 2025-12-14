class SmartChaser
  TILE_EMPTY = 0
  TILE_CHARACTER = 1
  TILE_BLOCK = 2
  TILE_ITEM = 3
  TILE_UNKNOWN = -1

  # マップサイズ（U-16プロコン北海道大会ルール v3.0.1準拠）
  MAP_WIDTH = 15
  MAP_HEIGHT = 17
  MAP_CENTER = [MAP_WIDTH / 2, MAP_HEIGHT / 2].freeze  # [7, 8]

  # ターン数範囲
  MIN_TURNS = 100
  MAX_TURNS = 240
  DEFAULT_TURNS = 200

  # 得点計算
  ITEM_SCORE_MULTIPLIER = 3

  INDEX_TO_OFFSET = {
    1 => [-1, -1],
    2 => [0, -1],
    3 => [1, -1],
    4 => [-1, 0],
    5 => [0, 0],
    6 => [1, 0],
    7 => [-1, 1],
    8 => [0, 1],
    9 => [1, 1]
  }.freeze

  OFFSET_TO_INDEX = INDEX_TO_OFFSET.invert.freeze

  TRAPKAIHI_DIAGONALS = {
    up: [1, 3],
    right: [3, 9],
    down: [7, 9],
    left: [1, 7]
  }.freeze

  TRAPKAIHI_INDEX_TO_DIAGONALS = {
    2 => [1, 3],
    6 => [3, 9],
    8 => [7, 9],
    4 => [1, 7]
  }.freeze

  TRAP_SEARCH_DEAD_END_DISTANCE = 3
  TRAP_DEAD_END_THRESHOLD = 1
  TRAP_REQUIRED_ESCAPE_OPTIONS = 1

  DIAGONAL_INDEXES = [1, 3, 7, 9].freeze

  DIAGONAL_BLOCK_CANDIDATES = {
    1 => [:up, :left],
    3 => [:up, :right],
    7 => [:down, :left],
    9 => [:down, :right]
  }.freeze

  DIAGONAL_ESCAPE_OPTIONS = {
    1 => [:down, :right],
    3 => [:down, :left],
    7 => [:up, :right],
    9 => [:up, :left]
  }.freeze

  TRAP_DESCRIPTORS = %i[
    confirmed_trap
    pending_search
    suspected_trap
    confirmed_safe
  ].freeze

  def self.format_half_step(half_step)
    integer, remainder = half_step.divmod(2)
    remainder.zero? ? integer.to_s : "#{integer}.5"
  end

  if SMART_CHASER_GUI_AVAILABLE
    module SmartChaserUIRunner
      class << self
        def init_once
          return if initialized?

          (@init_mutex ||= Mutex.new).synchronize do
            return if initialized?

            @ready_queue = Queue.new
            @ui_thread = Thread.new do
              begin
                LibUI.init
                @initialized = true
                @ready_queue << :ok
                LibUI.main
              rescue StandardError => thread_error
                @ready_queue << thread_error
                raise thread_error
              ensure
                @initialized = false
              end
            end
            @ui_thread.name = 'SmartChaserUI' if @ui_thread.respond_to?(:name=)
            @ui_thread.abort_on_exception = true

            result = @ready_queue.pop
            if result.is_a?(Exception)
              @ui_thread = nil
              raise result
            end

            at_exit { shutdown }
          end
        end

        def run_main_loop
          init_once
        end

        def shutdown
          return unless initialized?

          if Thread.current == @ui_thread
            LibUI.quit
          else
            queue { LibUI.quit }
            @ui_thread&.join
          end
        rescue StandardError
          LibUI.quit rescue nil
        ensure
          @initialized = false
          @ui_thread = nil
        end

        def initialized?
          defined?(@initialized) && @initialized
        end

        def queue(&block)
          raise 'SmartChaser UI is not initialized' unless initialized?
          LibUI.queue_main(&block)
        end

        def queue_sync(&block)
          raise 'SmartChaser UI is not initialized' unless initialized?
          result_queue = Queue.new

          queue do
            begin
              result_queue << [:ok, block.call]
            rescue StandardError => e
              result_queue << [:error, e]
            end
          end

          status, payload = result_queue.pop
          raise payload if status == :error
          payload
        end
      end
    end

    class MapRenderer
      MIN_WIDTH = 320
      MIN_HEIGHT = 360
      CELL_SIZE = 28
      CELL_PADDING = 3
      BACKGROUND_COLOR = [0.06, 0.06, 0.08, 1.0].freeze

      DESCRIPTOR_COLORS = {
        empty: [1.0, 1.0, 1.0, 1.0],
        block: [0.70, 0.70, 0.76, 1.0],
        item: [0.10, 0.55, 0.45, 1.0],
        character: [0.35, 0.08, 0.08, 1.0],
        self: [0.10, 0.25, 0.45, 1.0],
        confirmed_trap: [0.28, 0.00, 0.28, 1.0],
        pending_search: [0.26, 0.22, 0.05, 1.0],
        suspected_trap: [0.32, 0.16, 0.06, 1.0],
        confirmed_safe: [0.82, 0.73, 0.94, 1.0],
        unknown: [0.10, 0.10, 0.14, 1.0],
        none: [0.08, 0.08, 0.12, 1.0]
      }.freeze

      OVERLAY_COLORS = {
        self: [0.30, 0.65, 1.00, 1.0],
        character: [0.95, 0.35, 0.35, 1.0],
        item: [0.18, 0.85, 0.70, 1.0],
        confirmed_trap: [0.85, 0.20, 0.85, 1.0],
        pending_search: [0.95, 0.95, 0.35, 1.0],
        suspected_trap: [1.00, 0.60, 0.25, 1.0],
        confirmed_safe: [0.90, 0.80, 0.96, 1.0]
      }.freeze

      def initialize
        @closed_mutex = Mutex.new
        @closed_condition = ConditionVariable.new
        @closed = false
        @latest_descriptors = nil
        @frames = []
        @current_index = nil
        @realtime = true
        @show_heatmap = true
        @button_callbacks = []
        @half_step_to_index = {}
        @updating_slider = false
        SmartChaserUIRunner.run_main_loop

        @draw_callback = make_closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_handler_ptr, _area_ptr, params_ptr|
          handle_draw(params_ptr)
        end
        @mouse_event_callback = make_closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_handler_ptr, _area_ptr, _event_ptr|
        end
        @mouse_crossed_callback = make_closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]) do |_handler_ptr, _area_ptr, _left|
        end
        @drag_broken_callback = make_closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_handler_ptr, _area_ptr|
        end
        @key_event_callback = make_closure(Fiddle::TYPE_INT, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_handler_ptr, _area_ptr, _key_event_ptr|
          0
        end
        @callbacks = [
          @draw_callback,
          @mouse_event_callback,
          @mouse_crossed_callback,
          @drag_broken_callback,
          @key_event_callback
        ]

        @area_handler = LibUI::FFI::AreaHandler.malloc
        zero_struct!(@area_handler, LibUI::FFI::AreaHandler.size)
        @area_handler.Draw = @draw_callback
        @area_handler.MouseEvent = @mouse_event_callback
        @area_handler.MouseCrossed = @mouse_crossed_callback
        @area_handler.DragBroken = @drag_broken_callback
        @area_handler.KeyEvent = @key_event_callback

        components = SmartChaserUIRunner.queue_sync do
          callbacks = []
          window = LibUI.new_window('🎮 Smart Chaser+ デバッグモニター', MIN_WIDTH + 80, MIN_HEIGHT + 140, 0)
          LibUI.window_set_margined(window, 1)

          vbox = LibUI.new_vertical_box
          LibUI.box_set_padded(vbox, 1)
          LibUI.window_set_child(window, vbox)

          # === ステータスグループ ===
          status_group = LibUI.new_group('📊 ステータス')
          LibUI.group_set_margined(status_group, 1)
          LibUI.box_append(vbox, status_group, 0)

          status_box = LibUI.new_vertical_box
          LibUI.box_set_padded(status_box, 1)
          LibUI.group_set_child(status_group, status_box)

          # ターン/位置情報
          header_label = LibUI.new_label('⏱ ターン: 0 | 📍 位置: [0, 0]')
          LibUI.box_append(status_box, header_label, 0)

          # ステータス行（水平レイアウト）
          status_row = LibUI.new_horizontal_box
          LibUI.box_set_padded(status_row, 1)
          LibUI.box_append(status_box, status_row, 0)

          strategy_label = LibUI.new_label('🎯 戦略: バランス')
          items_label = LibUI.new_label('💎 アイテム: 0')
          enemy_label = LibUI.new_label('👾 敵距離: -')

          LibUI.box_append(status_row, strategy_label, 1)
          LibUI.box_append(status_row, items_label, 1)
          LibUI.box_append(status_row, enemy_label, 1)

          # === 意思決定グループ ===
          decision_group = LibUI.new_group('🧠 意思決定')
          LibUI.group_set_margined(decision_group, 1)
          LibUI.box_append(vbox, decision_group, 0)

          decision_box = LibUI.new_vertical_box
          LibUI.box_set_padded(decision_box, 1)
          LibUI.group_set_child(decision_group, decision_box)

          action_label = LibUI.new_label('▶ 行動: -')
          reason_label = LibUI.new_label('💡 理由: -')
          
          LibUI.box_append(decision_box, action_label, 0)
          LibUI.box_append(decision_box, reason_label, 0)

          # === 凡例 ===
          legend_label = LibUI.new_label('🗺 凡例: ⬜空 🟦自分 🟥敵 🟩アイテム ⬛ブロック 🟪トラップ')
          LibUI.box_append(vbox, legend_label, 0)

          # === コントロールグループ ===
          controls_box = LibUI.new_horizontal_box
          LibUI.box_set_padded(controls_box, 1)
          LibUI.box_append(vbox, controls_box, 0)

          back_button = LibUI.new_button('⏮ 戻る')
          forward_button = LibUI.new_button('進む ⏭')
          realtime_button = LibUI.new_button('🔴 リアルタイム: ON')

          back_proc = proc { navigate_relative(-1) }
          forward_proc = proc { navigate_relative(1) }
          realtime_proc = proc { toggle_realtime }

          LibUI.button_on_clicked(back_button, &back_proc)
          LibUI.button_on_clicked(forward_button, &forward_proc)
          LibUI.button_on_clicked(realtime_button, &realtime_proc)

          heatmap_button = LibUI.new_button('🔥 ヒートマップ: ON')
          heatmap_proc = proc { toggle_heatmap }
          LibUI.button_on_clicked(heatmap_button, &heatmap_proc)

          callbacks.concat([back_proc, forward_proc, realtime_proc, heatmap_proc])

          LibUI.box_append(controls_box, back_button, 0)
          LibUI.box_append(controls_box, forward_button, 0)
          LibUI.box_append(controls_box, realtime_button, 0)
          LibUI.box_append(controls_box, heatmap_button, 0)

          position_label = LibUI.new_label('現在: 0手目 / 全0手')
          LibUI.box_append(vbox, position_label, 0)

          slider = LibUI.new_slider(0, 0)
          LibUI.slider_set_value(slider, 0)
          slider_proc = proc do |_slider, _data|
            next if @updating_slider
            slider_value_changed(LibUI.slider_value(slider))
          end
          LibUI.slider_on_changed(slider, &slider_proc)
          callbacks << slider_proc
          LibUI.box_append(vbox, slider, 0)

          jump_box = LibUI.new_horizontal_box
          LibUI.box_set_padded(jump_box, 1)
          LibUI.box_append(vbox, jump_box, 0)

          jump_label = LibUI.new_label('指定移動: ')
          LibUI.box_append(jump_box, jump_label, 0)

          jump_entry = LibUI.new_entry
          LibUI.entry_set_text(jump_entry, '0')
          LibUI.box_append(jump_box, jump_entry, 1)

          jump_button = LibUI.new_button('移動')
          jump_proc = proc { jump_to_entered_move }
          LibUI.button_on_clicked(jump_button, &jump_proc)
          callbacks << jump_proc
          LibUI.box_append(jump_box, jump_button, 0)

          area = LibUI.new_scrolling_area(@area_handler, MIN_WIDTH, MIN_HEIGHT)
          LibUI.box_append(vbox, area, 1)

          LibUI.window_on_closing(window) do
            @closed_mutex.synchronize do
              @closed = true
              @closed_condition.broadcast
            end
            LibUI.control_destroy(window)
            SmartChaserUIRunner.shutdown
            0
          end

          LibUI.control_show(window)

          {
            window: window,
            vbox: vbox,
            header_label: header_label,
            legend_label: legend_label,
            strategy_label: strategy_label,
            items_label: items_label,
            enemy_label: enemy_label,
            action_label: action_label,
            reason_label: reason_label,
            controls_box: controls_box,
            back_button: back_button,
            forward_button: forward_button,
            realtime_button: realtime_button,
            heatmap_button: heatmap_button,
            position_label: position_label,
            position_slider: slider,
            jump_entry: jump_entry,
            jump_button: jump_button,
            area: area,
            callbacks: callbacks
          }
        end

        @window = components[:window]
        @vbox = components[:vbox]
        @header_label = components[:header_label]
        @legend_label = components[:legend_label]
        @strategy_label = components[:strategy_label]
        @items_label = components[:items_label]
        @enemy_label = components[:enemy_label]
        @action_label = components[:action_label]
        @reason_label = components[:reason_label]
        @controls_box = components[:controls_box]
        @back_button = components[:back_button]
        @forward_button = components[:forward_button]
        @realtime_button = components[:realtime_button]
        @heatmap_button = components[:heatmap_button]
        @position_label = components[:position_label]
        @position_slider = components[:position_slider]
        @jump_entry = components[:jump_entry]
        @jump_button = components[:jump_button]
        @area = components[:area]
        @button_callbacks.concat(components[:callbacks])

        SmartChaserUIRunner.queue do
          update_realtime_button_label
          update_heatmap_button_label
          update_navigation_controls
          update_slider_range
          update_position_label
        end
      end

      def closed?
        @closed_mutex.synchronize { @closed || !SmartChaserUIRunner.initialized? }
      end

      def render(bounds, header, descriptor_rows, half_step, heatmap = nil, est_bounds = nil, out_bounds = nil)
        return if closed?
        return unless SmartChaserUIRunner.initialized?
        return if descriptor_rows.nil? || descriptor_rows.empty?

        cols = descriptor_rows.first&.length || 0
        rows_count = descriptor_rows.length
        return if cols.zero? || rows_count.zero?

        grid_width = cols * CELL_SIZE
        grid_height = rows_count * CELL_SIZE
        area_width = grid_width + CELL_PADDING * 4
        area_height = grid_height + CELL_PADDING * 4
        descriptors_copy = descriptor_rows.map { |row| row.dup }

        # ヘッダーからデバッグ情報を抽出
        debug_info = parse_debug_info(header)

        frame = {
          header: header.dup,
          half_step: half_step,
          descriptors: descriptors_copy,
          area_width: area_width,
          area_height: area_height,
          debug_info: debug_info,
          heatmap: heatmap && !heatmap.empty? ? heatmap.dup : nil,
          bounds: bounds,
          est_bounds: est_bounds,
          out_bounds: out_bounds
        }

        SmartChaserUIRunner.queue do
          next if closed?
          append_frame(frame)
          update_debug_labels(debug_info) if @realtime
        end
      end

      # ヘッダーからデバッグ情報をパース
      def parse_debug_info(header)
        info = { strategy: '-', items: '0', enemy_dist: '-', decision: '-' }
        
        if header.include?('戦略:')
          match = header.match(/戦略:([^\s\|]+)/)
          info[:strategy] = match[1] if match
        end
        
        if header.include?('アイテム:')
          match = header.match(/アイテム:(\d+)/)
          info[:items] = match[1] if match
        end
        
        if header.include?('敵距離:')
          match = header.match(/敵距離:(\d+)/)
          info[:enemy_dist] = match[1] if match
        end
        
        if header.include?('決定:')
          match = header.match(/決定:(.+?)(?:\s*\||$)/)
          info[:decision] = match[1].strip if match
        end
        
        info
      end

      # デバッグラベルを更新（新レイアウト対応）
      def update_debug_labels(info)
        return unless info
        
        # 戦略ラベル
        if @strategy_label
          strategy_icon = case info[:strategy]
                          when '攻撃重視' then '⚔️'
                          when '守備重視' then '🛡️'
                          when 'アイテム集中' then '💎'
                          when '探索重視' then '🔍'
                          else '🎯'
                          end
          LibUI.label_set_text(@strategy_label, "#{strategy_icon} 戦略: #{info[:strategy]}")
        end
        
        # アイテムラベル
        if @items_label
          items = info[:items].to_i
          icon = items >= 5 ? '💎💎' : '💎'
          LibUI.label_set_text(@items_label, "#{icon} アイテム: #{info[:items]}")
        end
        
        # 敵距離ラベル
        if @enemy_label
          dist = info[:enemy_dist]
          icon = case dist
                 when '-', nil then '👾'
                 when '1', '2' then '⚠️👾'
                 else '👾'
                 end
          LibUI.label_set_text(@enemy_label, "#{icon} 敵距離: #{dist || '-'}")
        end
        
        # 行動ラベル
        if @action_label && info[:decision]
          action = info[:decision].match(/(.+?)(?:で|を|へ|の)/) || [nil, info[:decision]]
          LibUI.label_set_text(@action_label, "▶ 行動: #{action[1] || info[:decision]}")
        end
        
        # 理由ラベル
        if @reason_label && info[:decision]
          LibUI.label_set_text(@reason_label, "💡 理由: #{info[:decision]}")
        end
      rescue StandardError
        # ラベル更新エラーは無視
      end

      def wait_until_closed
        @closed_mutex.synchronize do
          @closed_condition.wait(@closed_mutex) unless @closed
        end
      end

      private

      def legend_text
        'Legend: Empty=White, Safe=Lavender, Item=Emerald, You=Blue, Enemy=Red, Trap=Purple'
      end

      def make_closure(return_type, param_types, &block)
        Fiddle::Closure::BlockCaller.new(return_type, param_types, &block)
      end

      def handle_draw(params_ptr)
        descriptors = @latest_descriptors
        return unless descriptors

        params = LibUI::FFI::AreaDrawParams.new(params_ptr)
        context = params.Context

        fill_rect(context, 0, 0, params.AreaWidth, params.AreaHeight, BACKGROUND_COLOR)
        draw_cells(context, descriptors, params.AreaWidth, params.AreaHeight, @latest_heatmap, @latest_bounds, @latest_est_bounds, @latest_out_bounds)
      end

      def draw_cells(context, descriptors, area_width, area_height, heatmap, bounds, est_bounds, out_bounds)
        rows = descriptors.length
        cols = descriptors.first ? descriptors.first.length : 0
        return if rows.zero? || cols.zero?

        grid_width = cols * CELL_SIZE
        grid_height = rows * CELL_SIZE
        offset_x = [(area_width - grid_width) / 2.0, CELL_PADDING * 2].max
        offset_y = [(area_height - grid_height) / 2.0, CELL_PADDING * 2].max
        cell_size = CELL_SIZE - CELL_PADDING * 2
        
        min_x = bounds ? bounds[0] : 0
        min_y = bounds ? bounds[2] : 0

        # ========== 1. 外側境界（可能性のある最大範囲）の描画 ==========
        if out_bounds
          o_min_x, o_max_x = out_bounds[:min_x], out_bounds[:max_x]
          o_min_y, o_max_y = out_bounds[:min_y], out_bounds[:max_y]
          
          # 枠線: 赤色（不確定性を表現）
          rect_x = offset_x + (o_min_x - min_x) * CELL_SIZE + CELL_PADDING
          rect_y = offset_y + (o_min_y - min_y) * CELL_SIZE + CELL_PADDING
          rect_w = (o_max_x - o_min_x + 1) * CELL_SIZE - CELL_PADDING * 2
          rect_h = (o_max_y - o_min_y + 1) * CELL_SIZE - CELL_PADDING * 2
          
          # 外側枠線（赤、少し薄め）
          stroke_rect(context, rect_x, rect_y, rect_w, rect_h, [1.0, 0.2, 0.2, 0.5], 2)
        end

        # ========== 2. 推定境界（安全圏）の描画 ==========
        # マゼンタ色の太枠...ではなく、青/緑
        if est_bounds
          # est_bounds は相対座標系での「確実なマップ範囲（Intersection）」
          e_min_x = est_bounds[:min_x]
          e_max_x = est_bounds[:max_x]
          e_min_y = est_bounds[:min_y]
          e_max_y = est_bounds[:max_y]

          rect_x = offset_x + (e_min_x - min_x) * CELL_SIZE
          rect_y = offset_y + (e_min_y - min_y) * CELL_SIZE
          rect_w = (e_max_x - e_min_x + 1) * CELL_SIZE
          rect_h = (e_max_y - e_min_y + 1) * CELL_SIZE
          
          rect_x += CELL_PADDING
          rect_y += CELL_PADDING
          rect_w -= CELL_PADDING * 2
          rect_h -= CELL_PADDING * 2
          
          # 枠線を描画
          if est_bounds[:localized]
            # 確定時は緑色 (太く)
            border_color = [0.0, 1.0, 0.0, 0.9] 
            thickness = 3
          else
            # 未確定時（安全圏）は青色
            border_color = [0.0, 0.5, 1.0, 0.7]
            thickness = 2
          end
          
          stroke_rect(context, rect_x, rect_y, rect_w, rect_h, border_color, thickness)
        end

        descriptors.each_with_index do |row, row_index|
          row.each_with_index do |descriptor, col_index|
            x = offset_x + col_index * CELL_SIZE + CELL_PADDING
            y = offset_y + row_index * CELL_SIZE + CELL_PADDING
            
            # ヒートマップモードかどうかで表示を変える
            if @show_heatmap && heatmap && bounds
              abs_x = min_x + col_index
              abs_y = min_y + row_index
              key = "#{abs_x},#{abs_y}"
              prob = heatmap[key] || 0.0
              
              # 確率に基づいてセルの色を決定
              if prob > 0.01
                # 確率が高いほど赤く、低いほど青く
                # 0.0 = 青 (0.2, 0.4, 0.8)
                # 1.0 = 赤 (0.9, 0.2, 0.2)
                r = 0.2 + prob * 0.7
                g = 0.4 - prob * 0.2
                b = 0.8 - prob * 0.6
                heat_color = [r, g, b, 1.0]
                fill_rect(context, x, y, cell_size, cell_size, heat_color)
                
                # 確率値をセルに表示するための枠線（高確率のみ）
                if prob > 0.1
                  # 赤い枠線を追加
                  draw_cell_border(context, x, y, cell_size, [1.0, 0.0, 0.0, 0.8])
                end
              else
                # 確率がない場合は通常のセル色
                base_color = DESCRIPTOR_COLORS.fetch(descriptor) { DESCRIPTOR_COLORS[:unknown] }
                fill_rect(context, x, y, cell_size, cell_size, base_color)
              end
            else
              # 通常モード
              base_color = DESCRIPTOR_COLORS.fetch(descriptor) { DESCRIPTOR_COLORS[:unknown] }
              fill_rect(context, x, y, cell_size, cell_size, base_color)
            end

            overlay_color = OVERLAY_COLORS[descriptor]
            next unless overlay_color

            overlay_size = cell_size * 0.5
            overlay_offset = (cell_size - overlay_size) / 2.0
            fill_rect(
              context,
              x + overlay_offset,
              y + overlay_offset,
              overlay_size,
              overlay_size,
              overlay_color
            )
          end
        end
      end

      # セルに枠線を描画
      def draw_cell_border(context, x, y, size, color)
        brush = LibUI::FFI::DrawBrush.malloc
        zero_struct!(brush, LibUI::FFI::DrawBrush.size)
        brush.Type = LibUI::DrawBrushTypeSolid
        brush.R = color[0]
        brush.G = color[1]
        brush.B = color[2]
        brush.A = color[3]

        stroke_params = LibUI::FFI::DrawStrokeParams.malloc
        zero_struct!(stroke_params, LibUI::FFI::DrawStrokeParams.size)
        stroke_params.Thickness = 2.0
        stroke_params.Cap = 0
        stroke_params.Join = 0
        stroke_params.MiterLimit = 10.0

        path = LibUI.draw_new_path(LibUI::DrawFillModeWinding)
        LibUI.draw_path_add_rectangle(path, x, y, size, size)
        LibUI.draw_path_end(path)
        LibUI.draw_stroke(context, path, brush, stroke_params)
        LibUI.draw_free_path(path)
      end

      def append_frame(frame)
        @frames << frame
        @half_step_to_index[frame[:half_step]] = @frames.length - 1
        update_slider_range
        if @realtime || @current_index.nil?
          navigate_to(@frames.length - 1)
        else
          update_navigation_controls
          update_realtime_button_label
          update_position_label
        end
      end

      def navigate_relative(delta)
        return if @realtime
        return if @frames.empty? || @current_index.nil?

        navigate_to(@current_index + delta)
      end

      def navigate_to(index)
        return if @frames.empty?
        clamped_index = [[index, 0].max, @frames.length - 1].min
        @current_index = clamped_index
        frame = @frames[@current_index]

        @latest_descriptors = frame[:descriptors]
        @latest_heatmap = frame[:heatmap]
        @latest_bounds = frame[:bounds]
        @latest_est_bounds = frame[:est_bounds]
        @latest_out_bounds = frame[:out_bounds]
        
        LibUI.area_set_size(@area, frame[:area_width], frame[:area_height])
        LibUI.label_set_text(@header_label, frame[:header])
        LibUI.label_set_text(@legend_label, legend_text)
        LibUI.area_queue_redraw_all(@area)

        # デバッグラベルを更新（過去のフレームでも表示）
        update_debug_labels(frame[:debug_info])

        with_slider_update do
          LibUI.slider_set_value(@position_slider, frame[:half_step]) if @position_slider
        end
        LibUI.entry_set_text(@jump_entry, SmartChaser.format_half_step(frame[:half_step])) if @jump_entry

        update_navigation_controls
        update_realtime_button_label
        update_position_label
      end

      def toggle_realtime
        @realtime = !@realtime
        if @realtime
          navigate_to(@frames.length - 1) unless @frames.empty?
        end
        update_slider_range
        update_navigation_controls
        update_realtime_button_label
        update_position_label
      end

      def update_navigation_controls
        back_enabled = !@realtime && @frames.any? && @current_index && @current_index > 0
        forward_enabled = !@realtime && @frames.any? && @current_index && @current_index < @frames.length - 1

        set_control_enabled(@back_button, back_enabled)
        set_control_enabled(@forward_button, forward_enabled)

        navigation_enabled = !@realtime && @frames.length > 1
        set_control_enabled(@position_slider, navigation_enabled)
        jump_enabled = !@realtime && @frames.any?
        set_control_enabled(@jump_entry, jump_enabled)
        set_control_enabled(@jump_button, jump_enabled)
      end

      def update_realtime_button_label
        label = @realtime ? 'リアルタイム: ON' : 'リアルタイム: OFF'
        LibUI.button_set_text(@realtime_button, label)
        set_control_enabled(@realtime_button, true)
      end

      def toggle_heatmap
        @show_heatmap = !@show_heatmap
        update_heatmap_button_label
        # 再描画
        LibUI.area_queue_redraw_all(@area) if @area
      end

      def update_heatmap_button_label
        return unless @heatmap_button
        label = @show_heatmap ? '🔥 ヒートマップ: ON' : '🗺️ マップ: ON'
        LibUI.button_set_text(@heatmap_button, label)
      end

      def set_control_enabled(control, enabled)
        return unless control
        if enabled
          LibUI.control_enable(control)
        else
          LibUI.control_disable(control)
        end
      end

      def update_slider_range
        return unless @position_slider
        max_half_step = @frames.empty? ? 0 : @frames.last[:half_step]
        with_slider_update do
          LibUI.slider_set_range(@position_slider, 0, max_half_step)
          LibUI.slider_set_value(@position_slider, current_half_step_value)
        end
      end

      def update_position_label
        return unless @position_label
        if @frames.empty? || @current_index.nil?
          total = @frames.empty? ? 0 : @frames.last[:half_step]
          LibUI.label_set_text(@position_label, "現在: 0手目 / 全#{SmartChaser.format_half_step(total)}手")
          LibUI.entry_set_text(@jump_entry, '0') if @jump_entry
        else
          current_half = @frames[@current_index][:half_step]
          total_half = @frames.last[:half_step]
          LibUI.label_set_text(@position_label, "現在: #{SmartChaser.format_half_step(current_half)}手目 / 全#{SmartChaser.format_half_step(total_half)}手")
          LibUI.entry_set_text(@jump_entry, SmartChaser.format_half_step(current_half)) if @jump_entry
        end
      end

      def slider_value_changed(value)
        return if @realtime
        return if @frames.empty?
        navigate_to_half_step(value)
      end

      def jump_to_entered_move
        return if @frames.empty?
        return if @realtime
        return unless @jump_entry
        text = LibUI.entry_text(@jump_entry)
        half_step = parse_half_step_text(text)
        return if half_step.nil?

        navigate_to_half_step(half_step)
      end

      def navigate_to_half_step(half_step)
        return if @frames.empty?
        clamped = [[half_step, 0].max, @frames.last[:half_step]].min
        index = @half_step_to_index.fetch(clamped, nil)
        unless index
          index = @frames.find_index { |frame| frame[:half_step] >= clamped } || @frames.length - 1
        end
        navigate_to(index)
      end

      def current_half_step_value
        if @frames.empty?
          0
        elsif @current_index
          @frames[@current_index][:half_step]
        else
          @frames.last[:half_step]
        end
      end

      def parse_half_step_text(text)
        return nil if text.nil?
        cleaned = text.strip
        return nil if cleaned.empty?
        value = begin
          Float(cleaned)
        rescue ArgumentError
          nil
        end
        return nil unless value
        scaled = value * 2
        half_step = scaled.round
        return nil unless (scaled - half_step).abs < 1e-6
        half_step
      end

      def with_slider_update
        previous = @updating_slider
        @updating_slider = true
        yield
      ensure
        @updating_slider = previous
      end

      def fill_rect(context, x, y, width, height, color)
        brush = LibUI::FFI::DrawBrush.malloc
        zero_struct!(brush, LibUI::FFI::DrawBrush.size)
        brush.Type = LibUI::DrawBrushTypeSolid
        brush.R = color[0]
        brush.G = color[1]
        brush.B = color[2]
        brush.A = color[3]

        path = LibUI.draw_new_path(LibUI::DrawFillModeWinding)
        LibUI.draw_path_add_rectangle(path, x, y, width, height)
        LibUI.draw_path_end(path)
        LibUI.draw_fill(context, path, brush)
        LibUI.draw_free_path(path)
      end

      def stroke_rect(context, x, y, width, height, color, thickness)
        brush = LibUI::FFI::DrawBrush.malloc
        zero_struct!(brush, LibUI::FFI::DrawBrush.size)
        brush.Type = LibUI::DrawBrushTypeSolid
        brush.R = color[0]
        brush.G = color[1]
        brush.B = color[2]
        brush.A = color[3]

        stroke_params = LibUI::FFI::DrawStrokeParams.malloc
        zero_struct!(stroke_params, LibUI::FFI::DrawStrokeParams.size)
        stroke_params.Cap = LibUI::DrawLineCapFlat
        stroke_params.Join = LibUI::DrawLineJoinMiter
        stroke_params.Thickness = thickness
        stroke_params.MiterLimit = 10.0

        path = LibUI.draw_new_path(LibUI::DrawFillModeWinding)
        LibUI.draw_path_add_rectangle(path, x, y, width, height)
        LibUI.draw_path_end(path)

        LibUI.draw_stroke(context, path, brush, stroke_params)
        LibUI.draw_free_path(path)
      end

      def zero_struct!(struct, size)
        ptr = struct.to_ptr
        ptr.clear(size) if ptr.respond_to?(:clear)
        ptr[0, size] = "\0".b * size
      end
    end
  end


  DIRECTIONS = {
    up:    {index: 2, walk: :walkUp,   put: :putUp,   search: :searchUp,   look: :lookUp},
    right: {index: 6, walk: :walkRight,put: :putRight,search: :searchRight,look: :lookRight},
    down:  {index: 8, walk: :walkDown, put: :putDown, search: :searchDown, look: :lookDown},
    left:  {index: 4, walk: :walkLeft, put: :putLeft, search: :searchLeft,  look: :lookLeft}
  }.freeze

  DIRECTION_DELTAS = {
    up: [0, -1],
    right: [1, 0],
    down: [0, 1],
    left: [-1, 0]
  }.freeze

end
