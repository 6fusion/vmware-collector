namespace :seed do
  desc 'Seed Mongo Data. Params: num_infs, num_machs'
  task :all do
    STDOUT.sync = true
    infrastructure_count = (ENV['infrastructures'] || 1).to_i
    machine_count = (ENV['machines'] || 20).to_i
    sample_count = (ENV['samples_per_machine'] || 10).to_i
    max_threads = (ENV['max_threads'] || 20).to_i

   puts "Removing all data"
    Infrastructure.delete_all
    Machine.delete_all
    InventoriedTimestamp.delete_all
    Reading.delete_all

    infrastructure_count.times do |inf|
      inf_id = inf+1
      new_inf = Infrastructure.new(name: "seed_inf_#{inf_id}",
                                   platform_id: "seed_inf_#{inf_id}",
                                   custom_id: "seed_inf_#{inf_id}",
                                   record_status: 'created')

      new_inf.save
      thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1, max_threads: max_threads, max_queue: max_threads * 2, fallback_policy: :caller_runs)
      print 'Creating machines'
      machine_count.times do |m|
        thread_pool.post do
          print '.'
          m_id = m+1
          uuid = SecureRandom.uuid
          new_machine = Machine.new(
            platform_id: "seed_vm-#{m_id}",
            record_status: "created",
            inventory_at: Time.now,
            uuid: uuid,
            name: "#{new_inf.platform_id}_vm_#{m_id}",
            virtual_name: "seed_virtual_name_#{m_id}",
            cpu_count: 2,
            cpu_speed_hz: 3000,
            memory_bytes: 2000,
            status: 'poweredOn',
            infrastructure_custom_id: "seed_inf_#{inf_id}")

          new_machine.save

          Reading.new(start_time: Time.now - 10.seconds,
                      end_time: Time.now,
                      machine_custom_id: uuid,
                      machine_metrics: { cpu_usage_percent: 50,
                                         memory_bytes: 10000 }).save
        end
      end
      thread_pool.shutdown
      thread_pool.wait_for_termination
    end
    puts "Mongo seeded"

  end
end
