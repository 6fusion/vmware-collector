# This module expects the host root (i.e., / ) to be mounted in the container
#  at /host
module HostCommandHelper

  # To ensure commands from the host OS get pointed at the correct libraries they
  #  depend on, we run said commands in a chroot. Since this irreversibly changes
  #  the environment of the proces that calls chroot, we have to run the command
  #  inside a forked process, so the parent's enviroment remains unchanged.
  # A pair of values is returned: the exit status of the command and any output
  def run(cmd)
    read_end, write_end = IO.pipe

    pid = fork do
      read_end.close
      Dir.chroot('/host')
      # Ruby seems to retain what it thinks is the CWD after the chroot, so the chdir is here to help clue it in that things have changed
      #  Otherwise you get a shell-init warning when the backtick command executes
      Dir.chdir('/')
      write_end.write `#{cmd}`
      write_end.close
      exit $?.exitstatus
    end

    write_end.close
    exit_code = Process.waitpid2(pid).last.exitstatus
    [exit_code, read_end.read]
  end

  module_function :run

end
