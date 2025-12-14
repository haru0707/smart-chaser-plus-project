require 'set'
require 'thread'
require 'fiddle'
require_relative '../CHaserConnect'

unless defined?(SMART_CHASER_GUI_AVAILABLE)
  begin
    require 'libui'
    SMART_CHASER_GUI_AVAILABLE = true
  rescue LoadError
    SMART_CHASER_GUI_AVAILABLE = false
  end
end

require_relative 'smart_chaser/constants'
require_relative 'smart_chaser/gameplay'
require_relative 'smart_chaser/strategy'
require_relative 'smart_chaser/rendering'
require_relative 'smart_chaser/utilities'

# 新規追加モジュール
require_relative 'smart_chaser/enemy_tracker'
require_relative 'smart_chaser/decision_logger'
require_relative 'smart_chaser/pathfinding'
require_relative 'smart_chaser/attack_strategy'
require_relative 'smart_chaser/scoring'
require_relative 'smart_chaser/map_symmetry'
require_relative 'smart_chaser/map_localizer'

