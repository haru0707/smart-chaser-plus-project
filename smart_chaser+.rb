# -*- coding: utf-8 -*-
# ローカルマップを構築し、ヒューリスティックに基づいて行動を選択するCHaser用スマートボット。
require_relative 'lib/core'

if __FILE__ == $PROGRAM_NAME
  bot = SmartChaser.new('smart_chaser-plus')
  bot.play
end

