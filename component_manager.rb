# su_component_options_enhancer/src/component_manager.rb

module ComponentOptionsEnhancer
  module ComponentManager
    # Obtiene el ComponentDefinition del componente seleccionado actualmente.
    # Retorna nil si no hay una selección válida.
    def self.get_selected_component_definition
      model = Sketchup.active_model
      selection = model.selection
      return nil if selection.empty? || selection[0].nil?

      # Tomamos el primer elemento de la selección.
      # Podríamos añadir lógica para manejar múltiples selecciones o si el
      # primer elemento no es una instancia de componente.
      selected_entity = selection[0]
      return nil unless selected_entity.is_a?(Sketchup::ComponentInstance)

      selected_entity.definition
    end

    # Lee los diccionarios de atributos de un ComponentDefinition y los prepara para la UI.
    # Incluye meta-atributos de Dynamic Components (DC) para una mejor representación.
    def self.get_component_options_data(definition)
      return {} if definition.nil?

      options_data = {}
      definition.attribute_dictionaries.each do |dictionary|
        dict_name = dictionary.name
        # No procesar diccionarios internos de DC que no son para el usuario directamente.
        # O podríamos tener una lista de diccionarios a excluir.
        next if dict_name.start_with?("dc_")

        processed_attributes = {}
        attributes_to_process = {}
        meta_attributes = {}

        # Separar atributos normales de meta-atributos de DC (que empiezan con '_')
        dictionary.each_pair do |key, value|
          if key.start_with?('_') && key.length > 1 # Evitar un solo '_'
            # Los meta-atributos se asocian con la clave principal (ej. _lenx_label para lenx)
            # main_key = key[1..].split('_', 2).first # Intenta obtener 'lenx' de '_lenx_label'
            # Esta heurística es frágil. Es mejor agruparlos por la clave principal.
            # Por ejemplo, si tenemos 'lenx', '_lenx_label', '_lenx_units'.
            # El script JS los buscará como `attributes['_lenx_label']`
            meta_attributes[key] = value
          else
            attributes_to_process[key] = value
          end
        end

        # Ahora, para cada atributo principal, adjuntar sus meta-atributos
        attributes_to_process.each_pair do |key, value|
          current_attr_data = { "value" => value } # El valor principal

          # Añadir meta-atributos relevantes para esta clave
          # (ej. _label, _units, _options, _description, _formtype)
          # El script JS los buscará directamente en el objeto del atributo.
          # Ejemplo: options_data["dynamic_attributes"]["lenx"] = { value: 10.0, _label: "Width", ... }
          # Esto es más complejo de lo que JS espera ahora.
          # JS espera: options_data["dynamic_attributes"]["lenx"] = 10.0
          #         y options_data["dynamic_attributes"]["_lenx_label"] = "Width"
          # Vamos a mantener la estructura plana que JS espera por ahora.
          processed_attributes[key] = value
        end

        # Añadir todos los meta-atributos al mismo nivel para que JS los encuentre
        meta_attributes.each_pair do |meta_key, meta_value|
          processed_attributes[meta_key] = meta_value
        end

        options_data[dict_name] = processed_attributes unless processed_attributes.empty?
      end
      options_data
    end

    # Actualiza los atributos de un ComponentDefinition.
    # 'options_to_update' es un hash { dict_name => { attr_key => new_value, ... } }
    # Los new_value vienen de JS y pueden ser String, Number, o Boolean.
    def self.update_component_options(definition, options_to_update)
      return false if definition.nil? || options_to_update.nil?

      model = Sketchup.active_model
      model.start_operation('Update Component Options', true)
      success = true

      options_to_update.each_pair do |dict_name, attributes|
        dictionary = definition.attribute_dictionary(dict_name, true) # Crear si no existe
        attributes.each_pair do |key, new_value_from_js|
          begin
            current_value = definition.get_attribute(dict_name, key)
            final_value = new_value_from_js

            # --- Conversión de Tipos ---
            # 1. Si el atributo original es Length
            if current_value.is_a?(Length)
              begin
                # JS envía números para inputs numéricos, o strings.
                # .to_l funciona con números o strings como "10cm".
                final_value = new_value_from_js.to_l
              rescue ArgumentError, NoMethodError => e # NoMethodError para booleans .to_l
                puts "WARN: Could not convert '#{new_value_from_js}' to Length for #{dict_name}/#{key}. Original: #{current_value}. Error: #{e.message}"
                # Mantener el valor original o intentar una conversión más simple si es solo número
                final_value = new_value_from_js.to_f if new_value_from_js.is_a?(Numeric) || (new_value_from_js.is_a?(String) && new_value_from_js.match?(/^[\d\.]+$/))
                final_value = final_value.to_l # Intentar de nuevo
              end
            # 2. Si el atributo original es Float
            elsif current_value.is_a?(Float)
              final_value = new_value_from_js.to_f
            # 3. Si el atributo original es Integer (esto incluye 0/1 para booleanos de DC)
            elsif current_value.is_a?(Integer)
              # JS envía true/false para checkboxes, o números/strings para otros inputs.
              if new_value_from_js.is_a?(TrueClass)
                final_value = 1
              elsif new_value_from_js.is_a?(FalseClass)
                final_value = 0
              else
                final_value = new_value_from_js.to_i
              end
            # 4. Si el atributo original es String, o no hay valor original (nuevo atributo)
            elsif current_value.is_a?(String) || current_value.nil?
               # Si JS envía un booleano, convertirlo a string "true"/"false"
               if new_value_from_js.is_a?(TrueClass)
                 final_value = "true"
               elsif new_value_from_js.is_a?(FalseClass)
                 final_value = "false"
               else
                 final_value = new_value_from_js.to_s # Asegurar que es string
               end
            # 5. Si el atributo original es Boolean (raro en DC, suelen usar Integer 0/1)
            elsif current_value.is_a?(TrueClass) || current_value.is_a?(FalseClass)
              # JS envía true/false para checkboxes. Si es string "true"/"false", convertir.
              if new_value_from_js.is_a?(String)
                final_value = new_value_from_js.strip.downcase == "true"
              else
                final_value = !!new_value_from_js # Coerción a booleano
              end
            end

            # Debug:
            # puts "Updating #{dict_name}/#{key}: JS val: #{new_value_from_js.inspect} (type: #{new_value_from_js.class}), Current SU val: #{current_value.inspect} (type: #{current_value.class}), Final val: #{final_value.inspect} (type: #{final_value.class})"

            definition.set_attribute(dict_name, key, final_value)

          rescue StandardError => e
            puts "ERROR: Failed to set attribute #{dict_name}/#{key} with value #{new_value_from_js.inspect}."
            puts e.message
            puts e.backtrace.join("\n")
            success = false # Marcar que algo falló
          end
        end
      end

      # Forzar redibujo de instancias para que los DCs se actualicen
      # Esto es importante para que los cambios visuales y las fórmulas se apliquen.
      # Usar `definition.invalidate_bounds` podría ser necesario si la geometría cambia
      # de forma que el bounding box se vea afectado.
      # `redraw_invalidated` es para la representación visual.
      definition.instances.each(&:redraw_invalidated)

      # Si la extensión de DC está presente y activa, se puede intentar una actualización más directa.
      # Esto es más robusto que solo redraw_invalidated para algunos casos de DC.
      if Sketchup.respond_to?(:dynamic_components) && Sketchup.dynamic_components
         definition.instances.each do |inst|
           Sketchup.dynamic_components.redraw(inst)
         end
      end


      if success
        model.commit_operation
        true
      else
        model.abort_operation
        # UI.messagebox("Some options could not be updated. Check Ruby console for details.")
        false
      end

    rescue StandardError => e # Error en la operación general
      Sketchup.active_model.abort_operation
      puts "FATAL ERROR during update_component_options: #{e.message}"
      puts e.backtrace.join("\n")
      false
    end

  end
end

puts "ComponentManager (v2) loaded" # Para depuración
