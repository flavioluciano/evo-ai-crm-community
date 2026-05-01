class AddTypeToContacts < ActiveRecord::Migration[7.1]
  def up
    conn = ActiveRecord::Base.connection
    unless conn.select_value('SELECT EXISTS (SELECT 1 FROM pg_type WHERE typname = \'contact_type_enum\')')
      execute <<-SQL
        CREATE TYPE contact_type_enum AS ENUM ('person', 'company');
      SQL
    end

    return if column_exists?(:contacts, :type)

    add_column :contacts, :type, :contact_type_enum, default: 'person', null: false
    add_index :contacts, :type unless index_exists?(:contacts, :type)

    Contact.where(type: nil).update_all(type: 'person')
  end

  def down
    remove_index :contacts, :type
    remove_column :contacts, :type
    
    # Remover tipo ENUM do PostgreSQL
    execute <<-SQL
      DROP TYPE IF EXISTS contact_type_enum;
    SQL
  end
end
