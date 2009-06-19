module CouchRest
  module Mixins
    module Collection
  
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods

        # Creates a new class method, find_all_<collection_name> on the class
        # that will execute the view specified in the collection_options,
        # along with all view options specified.  This method will return the
        # results of the view as an Array of objects which are instances of the
        # class.
        #
        # This method is handy for objects that do not use the view_by method
        # to declare their views.
        #
        def provides_collection(collection_name, collection_options)
          class_eval <<-END, __FILE__, __LINE__ + 1
            def self.find_all_#{collection_name}(options = {})
              design_doc = "#{collection_options[:through].delete(:design_doc)}"
              view_name = "#{collection_options[:through].delete(:view_name)}"
              view_options = #{collection_options[:through].inspect} || {}
              CollectionProxy.new(@database, design_doc, view_name, view_options.merge(options), Kernel.const_get('#{self}'))
            end
          END
        end

        def paginate(options)
          proxy = create_collection_proxy(options)
          proxy.paginate(options)
        end

        def paginated_each(options, &block)
          proxy = create_collection_proxy(options)
          proxy.paginated_each(options, &block)
        end

        def collection_proxy_for(design_doc, view_name, view_options = {})
          options = view_options.merge(:design_doc => design_doc, :view_name => view_name)
          create_collection_proxy(options)
        end

        private

        def create_collection_proxy(options)
          design_doc, view_name, view_options = parse_view_options(options)
          CollectionProxy.new(@database, design_doc, view_name, view_options, self)
        end

        def parse_view_options(options)
          design_doc = options.delete(:design_doc)
          raise ArgumentError, 'design_doc is required' if design_doc.nil?

          view_name = options.delete(:view_name)
          raise ArgumentError, 'view_name is required' if view_name.nil?

          default_view_options = (design_doc.class == Design && 
              design_doc['views'][view_name.to_s] &&
              design_doc['views'][view_name.to_s]["couchrest-defaults"]) || {}
          view_options = default_view_options.merge(options)

          [design_doc, view_name, view_options]
        end
      end

      class CollectionProxy
        alias_method :proxy_respond_to?, :respond_to?
        instance_methods.each { |m| undef_method m unless m =~ /(^__|^nil\?$|^send$|proxy_|^object_id$)/ }

        DEFAULT_PAGE = 1
        DEFAULT_PER_PAGE = 30

        def initialize(database, design_doc, view_name, view_options = {}, container_class = nil)
          raise ArgumentError, "database is a required parameter" if database.nil?

          @database = database
          @container_class = container_class

          strip_pagination_options(view_options)
          @view_options = view_options

          if design_doc.class == Design
            @view_name = "#{design_doc.name}/#{view_name}"
          else
            @view_name = "#{design_doc}/#{view_name}"
          end
        end

        def paginate(options = {})
          page, per_page = parse_options(options)
          results = @database.view(@view_name, @view_options.merge(pagination_options(page, per_page)))
          convert_to_container_array(results)
        end

        def paginated_each(options = {}, &block)
          page, per_page = parse_options(options)

          begin
            collection = paginate({:page => page, :per_page => per_page})
            collection.each(&block)
            page += 1
          end until collection.size < per_page
        end

        def respond_to?(*args)
          proxy_respond_to?(*args) || (load_target && @target.respond_to?(*args))
        end

        # Explicitly proxy === because the instance method removal above
        # doesn't catch it.
        def ===(other)
          load_target
          other === @target
        end

        private

        def method_missing(method, *args)
          if load_target
            if block_given?
              @target.send(method, *args)  { |*block_args| yield(*block_args) }
            else
              @target.send(method, *args)
            end
          end
        end

        def load_target
          unless loaded?
            results = @database.view(@view_name, @view_options)
            @target = convert_to_container_array(results)
          end
          @loaded = true
          @target
        end

        def loaded?
          @loaded
        end

        def reload
          reset
          load_target
          self unless @target.nil?
        end

        def reset
          @loaded = false
          @target = nil
        end

        def inspect
          load_target
          @target.inspect
        end

        def convert_to_container_array(results)
          if @container_class.nil?
            results
          else
            results['rows'].collect { |row| @container_class.new(row['doc']) } unless results['rows'].nil?
          end
        end

        def pagination_options(page, per_page)
          { :limit => per_page, :skip => per_page * (page - 1) }
        end

        def parse_options(options)
          page = options.delete(:page) || DEFAULT_PAGE
          per_page = options.delete(:per_page) || DEFAULT_PER_PAGE
          [page.to_i, per_page.to_i]
        end

        def strip_pagination_options(options)
          parse_options(options)
        end
      end

    end
  end
end