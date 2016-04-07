class Version
  include Comparable
  attr_accessor :major, :minor, :patch

  VERSION_REGEXP = /\d+(?:\.\d+){0,2}$/o

  def initialize(version_string=default_value)
    md = version_string.match(/(#{VERSION_REGEXP})/)
    if ( md )
      @major,@minor,@patch = md[1].split('.').map(&:to_i) #robust enough? !!
      @minor ||= 0
      @patch ||= 0
    else
      @major, @minor, @patch = [default_value,0,0]
    end
  end

  def <=>(other)
    [:major, :minor, :patch].each {|level|
      return self.level_to_i(level) <=> other.level_to_i(level) unless self.level_to_i(level) == other.level_to_i(level) }
    0
  end

  def to_s
    case major
      when 'alpha' then 'alpha'
      when 'beta'  then 'beta'
      else major.to_s +
           (minor ? ".#{minor}" : '').to_s +
           (patch ? ".#{patch}" : '')
    end
  end

  # Promote/demote alpha and beta versions, depending on the environment (9000 just chosen as an unbelievably high number)
  def level_to_i(lvl_sym)
    lvl_val = self.send(lvl_sym)
    case lvl_val
      when 'alpha' then Rails.env.eql?('development') ? 9000 : -9000
      when 'beta'  then Rails.env.eql?('staging')     ? 9000 : -9000
      else lvl_val.to_i
    end
  end

  private
  def default_value
    case Rails.env
      when 'development' then 'alpha'
      when 'staging'     then 'beta'
      when 'production'  then '0'
    end
  end
end
