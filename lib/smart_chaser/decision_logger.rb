# -*- coding: utf-8 -*-
# 意思決定ログ・ツリー表示モジュール

class SmartChaser
  # 意思決定ログシステムを初期化
  def init_decision_logger
    @decision_log = []
    @current_decision_tree = nil
    @debug_mode = ENV['SMART_CHASER_DEBUG'] == '1'
  end

  # 意思決定ツリーを開始
  def start_decision_tree(context = {})
    @current_decision_tree = {
      turn: @turn_count,
      position: @position.dup,
      context: context,
      branches: [],
      selected: nil,
      timestamp: Time.now
    }
  end

  # 判断分岐を追加
  def add_decision_branch(label, condition, result, score = nil, children: [])
    return unless @current_decision_tree

    branch = {
      label: label,
      condition: condition,
      result: result,
      score: score,
      children: children
    }
    @current_decision_tree[:branches] << branch
    branch
  end

  # 選択された行動を記録
  def select_decision(action, reason)
    return unless @current_decision_tree

    @current_decision_tree[:selected] = {
      action: action,
      reason: reason
    }
    
    # ログに追加
    finalize_decision_tree
  end

  # 決定ツリーを確定してログに追加
  def finalize_decision_tree
    return unless @current_decision_tree

    @decision_log << @current_decision_tree
    # 直近100件のみ保持
    @decision_log.shift if @decision_log.size > 100

    # 最後の決定を保存（GUI表示用）
    @last_decision = @current_decision_tree[:selected]

    # デバッグモードならツリーを出力
    print_decision_tree if @debug_mode
    
    @current_decision_tree = nil
  end

  # 決定ツリーをツリー形式で日本語出力
  def print_decision_tree
    tree = @current_decision_tree
    return unless tree

    STDERR.puts "=" * 50
    STDERR.puts "【意思決定ツリー】ターン #{tree[:turn]} | 位置 #{tree[:position].inspect}"
    STDERR.puts "-" * 50

    tree[:branches].each_with_index do |branch, i|
      prefix = i == tree[:branches].size - 1 ? "└" : "├"
      selected = tree[:selected] && tree[:selected][:action] == branch[:result]
      marker = selected ? " ★選択" : ""
      score_str = branch[:score] ? " (評価: #{format('%.2f', branch[:score])})" : ""
      
      STDERR.puts "#{prefix}─ #{branch[:label]}: #{branch[:condition] ? '✓' : '✗'}#{score_str}#{marker}"
      
      if branch[:result]
        child_prefix = i == tree[:branches].size - 1 ? "   " : "│  "
        STDERR.puts "#{child_prefix}└→ #{format_action_japanese(branch[:result])}"
      end
      
      # 子分岐があれば表示
      print_child_branches(branch[:children], i == tree[:branches].size - 1 ? "   " : "│  ")
    end

    if tree[:selected]
      STDERR.puts "-" * 50
      STDERR.puts "【決定】#{format_action_japanese(tree[:selected][:action])}"
      STDERR.puts "【理由】#{tree[:selected][:reason]}"
    end
    STDERR.puts "=" * 50
  end

  # 子分岐を再帰的に出力
  def print_child_branches(children, prefix)
    return if children.nil? || children.empty?

    children.each_with_index do |child, i|
      is_last = i == children.size - 1
      connector = is_last ? "└" : "├"
      score_str = child[:score] ? " (#{format('%.2f', child[:score])})" : ""
      
      STDERR.puts "#{prefix}#{connector}─ #{child[:label]}#{score_str}"
      
      new_prefix = prefix + (is_last ? "   " : "│  ")
      print_child_branches(child[:children], new_prefix)
    end
  end

  # アクションを日本語に変換
  def format_action_japanese(action)
    return "なし" unless action

    verb = case action[:verb]
           when :walk then "移動"
           when :put then "ブロック設置"
           when :search then "探索"
           when :look then "周囲確認"
           else action[:verb].to_s
           end

    direction = case action[:direction]
                when :up then "上"
                when :down then "下"
                when :left then "左"
                when :right then "右"
                else action[:direction].to_s
                end

    "#{verb} → #{direction}"
  end

  # デバッグモード切り替え
  def enable_debug_mode
    @debug_mode = true
  end

  def disable_debug_mode
    @debug_mode = false
  end
end
