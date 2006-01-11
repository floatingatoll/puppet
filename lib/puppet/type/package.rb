# Define the different packaging systems.  Each package system is implemented
# in a module, which then gets used to individually extend each package object.
# This allows packages to exist on the same machine using different packaging
# systems.

require 'puppet/type/state'

module Puppet
    class PackageError < Puppet::Error; end
    newtype(:package) do
        @doc = "Manage packages.  Eventually will support retrieving packages
            from remote sources but currently only supports packaging
            systems which can retrieve their own packages, like ``apt``."

        # Create a new packaging type
        def self.newpkgtype(name, parent = nil, &block)
            @pkgtypes ||= {}

            if @pkgtypes.include?(name)
                raise Puppet::DevError, "Package type %s already defined" % name
            end

            mod = Module.new

            # Add our parent, if it exists
            if parent
                unless @pkgtypes.include?(parent)
                    raise Puppet::DevError, "No parent type %s for package type %s" %
                        [parent, name]
                end
                mod.send(:include, @pkgtypes[parent])
            end

            # And now define the support methods
            code = %{
                def self.name
                    "#{name}"
                end

                def self.to_s
                    "PkgType(#{name})"
                end

                def pkgtype
                    "#{name}"
                end
            }

            mod.module_eval(code)

            mod.module_eval(&block)

            @pkgtypes[name] = mod
        end

        def self.pkgtype(name)
            @pkgtypes[name]
        end

        def self.pkgtypes
            @pkgtypes.keys
        end

        newstate(:install) do
            desc "What state the package should be in.  Specifying *true* will
                only result in a change if the package is not installed at all;
                use *latest* to keep the package (and, depending on the package
                system, its prerequisites) up to date.  Specifying *false* will
                uninstall the package if it is installed.
                *true*/*false*/*latest*/``version``"

            munge do |value|
                # possible values are: true, false, and a version number
                case value
                when "latest":
                    unless @parent.respond_to?(:latest)
                        self.err @parent.inspect
                        raise Puppet::Error,
                            "Package type %s cannot install later versions" %
                            @parent[:type].name
                    end
                    return :latest
                when true, :installed:
                    return :installed
                when false, :notinstalled:
                    return :notinstalled
                else
                    # We allow them to set a should value however they want,
                    # but only specific package types will be able to use this
                    # value
                    return value
                end
            end

            # Override the parent method, because we've got all kinds of
            # funky definitions of 'in sync'.
            def insync?
                # Iterate across all of the should values, and see how they
                # turn out.
                @should.each { |should|
                    case should
                    when :installed
                        unless @is == :notinstalled
                            return true
                        end
                    when :latest
                        latest = @parent.latest
                        if @is == latest
                            return true
                        else
                            self.debug "latest %s is %s" % [@parent.name, latest]
                        end
                    when :notinstalled
                        if @is == :notinstalled
                            return true
                        end
                    when @is
                        return true
                    end
                }

                return false
            end

            # This retrieves the current state
            def retrieve
                unless defined? @is
                    @parent.retrieve
                end
            end

            def sync
                method = nil
                event = nil
                case @should[0]
                when :installed:
                    method = :install
                    event = :package_installed
                when :notinstalled:
                    method = :remove
                    event = :package_removed
                when :latest
                    if @is == :notinstalled
                        method = :install
                        event = :package_installed
                    else
                        method = :update
                        event = :package_updated
                    end
                else
                    unless ! @parent.respond_to?(:versionable?) or @parent.versionable?
                        self.warning value
                        raise Puppet::Error,
                            "Package type %s does not support specifying versions" %
                            @parent[:type]
                    else
                        method = :install
                        event = :package_installed
                    end
                end

                if @parent.respond_to?(method)
                    begin
                        @parent.send(method)
                    rescue => detail
                        self.err "Could not run %s: %s" % [method, detail.to_s]
                        raise
                    end
                else
                    raise Puppet::Error, "Packages of type %s do not support %s" %
                        [@parent[:type], method]
                end

                return event
            end
        end
        # packages are complicated because each package format has completely
        # different commands.  We need some way to convert specific packages
        # into the general package object...
        attr_reader :version, :pkgtype

        newparam(:name) do
            desc "The package name."
            isnamevar
        end

        newparam(:type) do
            desc "The package format, e.g., rpm or dpkg."

            defaultto { @parent.class.default }

            # We cannot log in this routine, because this gets called before
            # there's a name for the package.
            munge do |type|
                @parent.type2module(type)
            end
        end

        newparam(:source) do
            desc "From where to retrieve the package."

            validate do |value|
                unless value =~ /^#{File::SEPARATOR}/
                    raise Puppet::Error,
                        "Package sources must be fully qualified files"
                end
            end
        end
        newparam(:instance) do
            desc "A read-only parameter set by the package."
        end
        newparam(:status) do
            desc "A read-only parameter set by the package."
        end
        #newparam(:version) do
        #    desc "A read-only parameter set by the package."
        #end
        newparam(:category) do
            desc "A read-only parameter set by the package."
        end
        newparam(:platform) do
            desc "A read-only parameter set by the package."
        end
        newparam(:root) do
            desc "A read-only parameter set by the package."
        end
        newparam(:vendor) do
            desc "A read-only parameter set by the package."
        end
        newparam(:description) do
            desc "A read-only parameter set by the package."
        end
        @name = :package
        @namevar = :name
        @listed = false

        @allowedmethods = [:types]

        @default = nil
        @platform = nil

        class << self
            attr_reader :listed
        end

        def self.clear
            @listed = false
            super
        end

        # Cache and return the default package type for our current
        # platform.
        def self.default
            if @default.nil?
                self.init
            end

            return @default
        end

        # Figure out what the default package type is for the platform
        # on which we're running.
        def self.init
            unless @platform = Facter["operatingsystem"].value.downcase
                raise Puppet::DevError.new(
                    "Must know platform for package management"
                )
            end
            case @platform
            when "solaris": @default = :sunpkg
            when "gentoo":
                Puppet.notice "No support for gentoo yet"
                @default = nil
            when "debian": @default = :apt
            when "fedora": @default = :yum
            when "redhat": @default = :rpm
            else
                if Facter["kernel"] == "Linux"
                    Puppet.warning "Defaulting to RPM for %s" %
                        Facter["operatingsystem"].value
                    @default = nil
                else
                    Puppet.warning "No default package system for %s" %
                        Facter["operatingsystem"].value
                    @default = nil
                end
            end
        end

        def self.getpkglist
            if @types.nil?
                if @default.nil?
                    self.init
                end
                @types = [@default]
            end

            list = @types.collect { |type|
                if typeobj = Puppet::PackagingType[type]
                    # pull all of the objects
                    typeobj.list
                else
                    raise "Could not find package type '%s'" % type
                end
            }.flatten
            @listed = true
            return list
        end

        def self.installedpkg(hash)
            # this is from code, so we don't have to do as much checking
            name = hash[:name]
            hash.delete(:name)

            # if it already exists, modify the existing one
            if object = Package[name]
                states = {}
                object.eachstate { |state|
                    Puppet.debug "Adding %s" % state.name.inspect
                    states[state.name] = state
                }
                hash.each { |var,value|
                    if states.include?(var)
                        Puppet.debug "%s is a set state" % var.inspect
                        states[var].is = value
                    else
                        Puppet.debug "%s is not a set state" % var.inspect
                        if object[var] and object[var] != value
                            Puppet.warning "Overriding %s => %s on %s with %s" %
                                [var,object[var],name,value]
                        end

                        #object.state(var).is = value

                        # swap the values if we're a state
                        if states.include?(var)
                            Puppet.debug "Swapping %s because it's a state" % var
                            states[var].is = value
                            states[var].should = nil
                        else
                            Puppet.debug "%s is not a state" % var.inspect
                            Puppet.debug "States are %s" % states.keys.collect { |st|
                                st.inspect
                            }.join(" ")
                        end
                    end
                }
                return object
            else # just create it
                obj = self.create(:name => name)
                hash.each { |var,value|
                    obj.addis(var,value)
                }
                return obj
            end
        end

        # okay, there are two ways that a package could be created...
        # either through the language, in which case the hash's values should
        # be set in 'should', or through comparing against the system, in which
        # case the hash's values should be set in 'is'
        def initialize(hash)
            self.initvars
            type = nil
            [:type, "type"].each { |label|
                if hash.include?(label)
                    type = hash[label]
                    hash.delete(label)
                end
            }
            if type
                self[:type] = type
            else
                self.setdefaults(:type)
            end

            super

            unless @states.include?(:install)
                self.debug "Defaulting to installing a package"
                self[:install] = true
            end

            unless @parameters.include?(:type)
                self[:type] = self.class.default
            end
        end

        def retrieve
            if hash = self.query
                hash.each { |param, value|
                    unless self.class.validattr?(param)
                        hash.delete(param)
                    end
                }

                hash.each { |param, value|
                    self.is = [param, value]
                }
            else
                self.class.validstates.each { |name|
                    self.is = [name, :notinstalled]
                }
            end
        end

        # Extend the package with the appropriate package type.
        def type2module(typename)
            if type = self.class.pkgtype(typename)
                self.extend(type)

                return type
            else
                raise Puppet::Error, "Invalid package type %s" % typename
            end
        end
    end # Puppet.type(:package)

    # this is how we retrieve packages
    class PackageSource
        attr_accessor :uri
        attr_writer :retrieve

        @@sources = Hash.new(false)

        def PackageSource.get(file)
            type = file.sub(%r{:.+},'')
            source = nil
            if source = @@sources[type]
                return source.retrieve(file)
            else
                raise "Unknown package source: %s" % type
            end
        end

        def initialize(name)
            if block_given?
                yield self
            end

            @@sources[name] = self
        end

        def retrieve(path)
            @retrieve.call(path)
        end

    end

    PackageSource.new("file") { |obj|
        obj.retrieve = proc { |path|
            # this might not work for windows...
            file = path.sub(%r{^file://},'')

            if FileTest.exists?(file)
                return file
            else
                raise "File %s does not exist" % file
            end
        }
    }
end

# The order these are loaded is important.
require 'puppet/type/package/dpkg.rb'
require 'puppet/type/package/apt.rb'
require 'puppet/type/package/rpm.rb'
require 'puppet/type/package/yum.rb'
require 'puppet/type/package/sun.rb'

# $Id$
