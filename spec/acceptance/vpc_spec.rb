require 'spec_helper_acceptance'
require 'securerandom'

describe "The AWS module" do

  before(:all) do
    @default_region = 'sa-east-1'
    @aws = AwsHelper.new(@default_region)
  end

  def finder(name, method)
    items = @aws.send(method, name)
    expect(items.count).to eq(1)
    items.first
  end

  def find_vpc(name)
    finder(name, 'get_vpcs')
  end

  def find_dhcp_option(name)
    finder(name, 'get_dhcp_options')
  end

  def find_route_table(name)
    finder(name, 'get_route_tables')
  end

  def find_subnet(name)
    finder(name, 'get_subnets')
  end

  def find_vpn_gateway(name)
    finder(name, 'get_vpn_gateways')
  end

  def find_internet_gateway(name)
    finder(name, 'get_internet_gateways')
  end

  def find_customer_gateway(name)
    finder(name, 'get_customer_gateways')
  end

  def find_vpn(name)
    finder(name, 'get_vpn')
  end

  def generate_ip
    # This generates a resolvable IP address within
    # a specific well populated range
    ip = "173.255.197.#{rand(255)}"
    begin
      Resolv.new.getname(ip)
      ip
    rescue
      generate_ip
    end
  end

  describe 'when creating a new VPC environment' do
    #TODO pair down to only what is required !!!!

    before(:all) do
      @name = "#{PuppetManifest.env_id}-#{SecureRandom.uuid}"
      region = 'sa-east-1'
      @config = {
        :name => @name,
        :region => region,
        :ensure => 'present',
        :netbios_node_type => 2,
        :vpc_cidr => '10.0.0.0/16',
        :vpc_instance_tenancy => 'default',
        :subnet_cidr => '10.0.0.0/24',
        :subnet_availability_zone => "#{region}a",
        :vpn_type => 'ipsec.1',
        :customer_ip_address => generate_ip,
        :bgp_asn => '65000',
        :vpn_route => '0.0.0.0/0',
        :static_routes => true,
        :tags => {
          :department => 'engineering',
          :project => 'cloud',
          :created_by => 'aws-acceptance',
        },
      }

      @template = 'vpc.pp.tmpl'
      @exit = PuppetManifest.new(@template, @config).apply[:exit_status]

      @vpc = find_vpc("#{@name}-vpc")
      @option = find_dhcp_option("#{@name}-options")
      @subnet = find_subnet("#{@name}-subnet")
      @vgw = find_vpn_gateway("#{@name}-vgw")
      @cgw = find_customer_gateway("#{@name}-cgw")
    end

    after(:all) do
      new_config = @config.update({:ensure => 'absent'})
      template = 'vpc_delete.pp.tmpl'
      PuppetManifest.new(template, new_config).apply
    end

    it 'should run successfully first time with changes' do
      expect(@exit.exitstatus).to eq(2)
    end

    it 'should run idempotently' do
      success = PuppetManifest.new(@template, @config).apply[:exit_status].success?
      expect(success).to eq(true)
    end

    it 'should create a VPC' do
      expect(@vpc).not_to be_nil
      expect(@vpc.instance_tenancy).to eq(@config[:vpc_instance_tenancy])
      expect(@vpc.cidr_block).to eq(@config[:vpc_cidr])
      expect(@vpc.dhcp_options_id).to eq(@option.dhcp_options_id)
    end

    it 'should create a DHCP option set' do
      node_type = @option.dhcp_configurations.find { |conf| conf.key == 'netbios-node-type' }
      expect(@option).not_to be_nil
      expect(node_type.values.first.value.to_i).to eq(@config[:netbios_node_type])
      expect(@aws.tag_difference(@option, @config[:tags])).to be_empty
    end

    it 'should create a route table' do
      table = find_route_table("#{@name}-routes")
      expect(table).not_to be_nil
      expect(table.vpc_id).to eq(@vpc.vpc_id)
      expect(table.associations.size).to eq(1)
      expect(table.associations.first.subnet_id).to eq(@subnet.subnet_id)
      expect(@aws.tag_difference(table, @config[:tags])).to be_empty
    end

    it 'should create a subnet' do
      expect(@subnet).not_to be_nil
      expect(@subnet.vpc_id).to eq(@vpc.vpc_id)
      expect(@subnet.cidr_block).to eq(@config[:subnet_cidr])
      expect(@subnet.availability_zone).to eq(@config[:subnet_availability_zone])
      expect(@subnet.map_public_ip_on_launch).to be_falsy
      expect(@subnet.default_for_az).to be_falsy
      expect(@aws.tag_difference(@subnet, @config[:tags])).to be_empty
    end

    it 'should create a VPN gateway' do
      expect(@vgw.type).to eq(@config[:vpn_type])
      expect(@vgw.vpc_attachments.size).to eq(1)
      expect(@vgw.vpc_attachments.first.vpc_id).to eq(@vpc.vpc_id)
      expect(@vgw.availability_zone).to be_nil
      expect(@aws.tag_difference(@vgw, @config[:tags])).to be_empty
    end

    it 'should create an internet gateway' do
      igw = find_internet_gateway("#{@name}-igw")
      expect(igw.attachments.size).to eq(1)
      expect(igw.attachments.first.vpc_id).to eq(@vpc.vpc_id)
      expect(@aws.tag_difference(igw, @config[:tags])).to be_empty
    end

    it 'should create an customer gateway' do
      expect(@cgw.type).to eq(@config[:vpn_type])
      expect(@cgw.ip_address).to eq(@config[:customer_ip_address])
      expect(@cgw.bgp_asn).to eq(@config[:bgp_asn])
      expect(@aws.tag_difference(@cgw, @config[:tags])).to be_empty
    end

    it 'should create a VPN' do
      vpn = find_vpn("#{@name}-vpn")
      expect(vpn.type).to eq(@config[:vpn_type])
      expect(vpn.vpn_gateway_id).to eq(@vgw.vpn_gateway_id)
      expect(vpn.customer_gateway_id).to eq(@cgw.customer_gateway_id)
      expect(vpn.routes.size).to eq(1)
      expect(vpn.routes.first.destination_cidr_block).to eq(@config[:vpn_route])
      expect(vpn.options.static_routes_only).to eq(@config[:static_routes])
      expect(@aws.tag_difference(vpn, @config[:tags])).to be_empty
    end

    it 'should allow tags to be changed' do
      expect(@aws.tag_difference(@vpc, @config[:tags])).to be_empty
      tags = {
        :department => 'engineering',
        :created_by => 'aws-acceptance',
        :foo => 'bar',
      }
      new_config = @config.dup.update(tags)
      PuppetManifest.new(@template, new_config).apply
      vpc = find_vpc("#{@name}-vpc")
      expect(@aws.tag_difference(vpc, new_config[:tags])).to be_empty
    end

    context 'using puppet resource' do

      before(:all) do
        result = PuppetManifest.new(@template, @config).apply
        expect(result[:output].any?{ |x| x.include? 'Error:'}).to eq(false)
      end

      context 'to describe an ec2_vpc' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-vpc"}
          @result = TestExecutor.puppet_resource('ec2_vpc', options, '--modulepath ../')
        end

        it 'should show the correct tenancy' do
          regex = /instance_tenancy\s*=>\s*'#{@config[:vpc_instance_tenancy]}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct cidr block' do
          regex = /cidr_block\s*=>\s*'#{Regexp.quote(@config[:vpc_cidr])}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct region' do
          regex = /region\s*=>\s*'#{@config[:region]}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

        it 'should show the correct dhcp_options' do
          pending('This test is blocked by CLOUD-234')
          regex = /'dhcp_options'\s*=>\s*'#{@name}-options'/
          expect(@result.stdout).to match(regex)
        end

      end

      context 'to describe an ec2_vpc_dhcp_options' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-options"}
          @result = TestExecutor.puppet_resource('ec2_vpc_dhcp_options', options, '--modulepath ../')
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct domain name servers' do
          #??? needs more info
        end

        it 'should show the correct ntp servers' do
          # needs more info
        end

        it 'should show the correct netbios name servers' do
          # needs more info
        end

        it 'should show the correct netbios node type' do
          regex = /'netbios_node_type'\s*=>\s*'#{@config[:netbios_node_type]}'/
          expect(@result.stdout).to match(regex)
        end

      end

      context 'to describe an ec2_vpc_routetable' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-routes"}
          @result = TestExecutor.puppet_resource('ec2_vpc_routetable', options, '--modulepath ../')
        end

        it 'should show the correct vpc' do
          regex = /'vpc'\s*=>\s*'#{@name}-vpc'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct routes' do
          # to specify or in manifest or not
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

      end

      context 'to describe an ec2_vpc_subnet' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-subnet"}
          @result = TestExecutor.puppet_resource('ec2_vpc_subnet', options, '--modulepath ../')
        end

        it 'should show the correct vpc' do
          regex = /'vpc'\s*=>\s*'#{@name}-vpc'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct cidr_block' do
          regex = /'cidr_block'\s*=>\s*'#{@config[:subnet_cidr]}'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct availability_zone' do
          regex = /'availability_zone'\s*=>\s*'#{@config[:subnet_availability_zone]}'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

        it 'should show the correct route_table' do
          regex = /'route_table'\s*=>\s*'#{@name}-routes'/
          expect(@result.stdout).to match(regex)
        end

      end

      context 'to describe an ec2_vpc_internet_gateway' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-igw"}
          @result = TestExecutor.puppet_resource('ec2_vpc_internet_gateway', options, '--modulepath ../')
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

        it 'should show the correct vpcs' do
          # vpc's plural ????
        end

      end

      context 'to describe an ec2_vpc_customer_gateway' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-cgw"}
          @result = TestExecutor.puppet_resource('ec2_vpc_customer_gateway', options, '--modulepath ../')
        end

        it 'should show the correct ip_address' do
          regex = /'ip_address'\s*=>\s*'#{@config[:customer_ip_address]}'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct bgp_asn' do
          regex = /'bgp_asn'\s*=>\s*'#{@config[:bgp_asn]}'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct type' do
          regex = /'type'\s*=>\s*'#{@config[:vpn_type]}'/
          expect(@result.stdout).to match(regex)
        end

      end

      context 'to describe an ec2_vpc_vpn' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-vpn"}
          @result = TestExecutor.puppet_resource('ec2_vpc_vpn', options, '--modulepath ../')
        end

        it 'should show the correct vpn_gateway' do
          regex = /'vpn_gateway'\s*=>\s*'#{@name}-vgw'/
        end

        it 'should show the correct customer_gateway' do
          regex = /'customer_gateway'\s*=>\s*'#{@name}-cgw'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct type' do
          regex = /'type'\s*=>\s*'#{@config[:vpn_type]}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct routes' do
          #routes plural

        end

        it 'should show the correct static_routes' do
          regex = /'static_routes'\s*=>\s*'#{@config[:static_routes].to_s}'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

      end

      context 'to describe an ec2_vpc_vpn_gateway' do

        before(:all) do
          ENV['AWS_REGION'] = @default_region
          options = {:name => "#{@name}-vgw"}
          @result = TestExecutor.puppet_resource('ec2_vpc_vpn_gateway', options, '--modulepath ../')
        end

        it 'should show the correct tags' do
          @config[:tags].each do |k,v|
            regex = /'#{k}'\s*=>\s*'#{v}'/
            expect(@result.stdout).to match(regex)
          end
        end

        it 'should show the correct vpc' do
          regex = /'vpc'\s*=>\s*'#{@name}-vpc'/
          expect(result.stdout).to match(regex)
        end

        it 'should show the correct region' do
          regex = /'region'\s*=>\s*'#{@default_region}'/
          expect(@result.stdout).to match(regex)
        end

        it 'should show the correct availability_zone' do
          # does not show? file bug
        end

        it 'should show the correct type' do
          regex = /'type'\s*=>\s*'#{@config[:vpn_type]}'/
          expect(@result.stdout).to match(regex)
        end

      end

    end
  end

  describe 'createing a new VPC environment with all possible properties' do

    before(:all) do
      @name = "#{PuppetManifest.env_id}-#{SecureRandom.uuid}"
      ip_address = generate_ip
      region = 'sa-east-1'
      @config = {
        :name => @name,
        :region => region,
        :ensure => 'present',
        :netbios_node_type => 2,
        :vpc_cidr => '10.0.0.0/16',
        :vpc_instance_tenancy => 'default',
        :subnet_cidr => '10.0.0.0/24',
        :subnet_availability_zone => "#{region}a",
        :vpn_type => 'ipsec.1',
        :customer_ip_address => ip_address,
        :bgp_asn => '65000',
        :vpn_route => '0.0.0.0/0',
        :static_routes => true,
        :tags => {
          :department => 'engineering',
          :project => 'cloud',
          :created_by => 'aws-acceptance',
        },
      }
    end

    after(:all) do

    end


  end

end
