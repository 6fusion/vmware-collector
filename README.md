## 6fusion VMware Collector

Follow us on Twitter [@6fusion](https://twitter.com/6fusion)

#### Requirements

* MongoDB
* Ruby 2.2

#### Getting started (Development only)

* `$ git clone git@github.com:6fusion/vmware-collector.git`
* cd vmware-collector
* bundle install
* Verify `config/{ENVIRONMENT}/mongoid.yml` file
* Create a “secrets” folder where you create 2 files: uc6 and vsphere (see samples on secrets_example folder)
* Execute `export SECRETS_PATH="PATH_TO_FOLDER_ON_STEP_4"`
* Run each of the files on `bin/` folder, `bin/inventory_collector.rb` generates all the configuration that we may require (and store inventory on the DB). Then `bin/metrics_collector.rb` will retrieve all the metrics for those elements

#### Usage

* Update the vSphere/UC6 configuration files (Secrets on step 4)
* For continual vSphere data collection, run the appropriate files under bin
* To perform a single collection and exit, use the appropriate rake task (rake -T collect to see available options)
* For Staging and production environment, is recommended to use `Docker` and `Kubernetes`