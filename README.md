## 6fusion VMware Meter

Follow us on Twitter [@6fusion](https://twitter.com/6fusion)

#### Requirements

* MongoDB
* Ruby 2.2


#### Getting started

* $ git clone git@github.com:6fusion/vmware-collector.git
* cd vmware-collector
* bundle install

#### Usage

* Update the vSphere configuration file (config/vsphere.yml) with appropriate credentials and URL
* For continual vSphere data collection, run the appropriate files under bin
* To perform a single collection and exit, use the appropriate rake task (rake -T collect to see available options)
