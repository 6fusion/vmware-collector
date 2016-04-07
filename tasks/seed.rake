namespace :seed do
  desc 'Seed Mongo Data. Params: num_infs, num_machs'
  task :all do
    raise 'Must pass params: num_infs= and num_machs=' unless (ENV['num_infs'] && ENV['num_machs'])

    num_infrastructures = ENV['num_infs'].to_i
    num_machines = ENV['num_machs'].to_i

    puts "Removing all data"
    Infrastructure.delete_all
    Machine.delete_all
    InventoriedTimestamp.delete_all
    Reading.delete_all
    PlatformRemoteId.delete_all

    puts "Seeding #{num_infrastructures} Infrastructures with #{num_machines} each"
    num_infrastructures.times do |inf|
      inf_id = inf+1
      new_inf = Infrastructure.new(name: "seed_inf_#{inf_id}",
                                   platform_id: "seed_inf_#{inf_id}",
                                   record_status: 'created',
                                   meter_instance: MeterInstance.new(name: "seed_vm_#{inf_id} meter", status: 'enabled'))
      new_inf.save

      num_machines.times do |m|
        m_id = m+1
        new_machine = Machine.new(
          platform_id: "seed_vm-#{m_id}",
          record_status: "created",
          inventory_at: Time.now,
          name: "#{new_inf.platform_id}_vm_#{m_id}",
          virtual_name: "seed_virtual_name_#{m_id}",
          cpu_count: 2,
          cpu_speed_mhz: 3000,
          memory_mb: 2000,
          status: 'poweredOn',
          infrastructure_platform_id: new_inf.platform_id,
          metrics: {})

        new_machine.save
      end
    end
  end
end
