require 'rubygems'
require 'fileutils'

if ENV.delete('COVERAGE')
  require 'simplecov'

  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
    add_group('Missing'){|src| src.covered_percent < 100}
    add_group('Covered'){|src| src.covered_percent == 100}
  end
end

require File.join(File.dirname(File.expand_path(__FILE__)), '../lib/sequel/annotate')

ENV['MT_NO_PLUGINS'] = '1' # Work around stupid autoloading of plugins
gem 'minitest'
require 'minitest/global_expectations/autorun'

DB = Sequel.connect(ENV['SEQUEL_ANNOTATE_SPEC_POSTGRES_URL'] || 'postgres:///sequel_annotate_test?user=sequel_annotate&password=sequel_annotate')
unless ENV['SEQUEL_ANNOTATE_SPEC_CI'] == '1' || DB.get{current_database.function} =~ /test\z/
  raise "test database name doesn't end with test"
end
if defined?(JRUBY_VERSION)
  SDB = Sequel.connect('jdbc:sqlite::memory:')
else
  SDB = Sequel.sqlite
end

DB.drop_function(:valid_price) rescue nil
[DB, SDB].each do |db|
  db.drop_table?(:newline_tests, :items, :manufacturers, :categories, :comment_tests, :fk_tests)

  db.create_table :categories do
    primary_key :id
    String :name, :index=>{:unique=>true, :name=>'categories_name_key'}, :null=>false
  end

  db.create_table :manufacturers do
    String :name
    String :location
    primary_key [:name, :location]
  end

  db.create_table :items do
    primary_key :id
    foreign_key :category_id, :categories, :null => false
    foreign_key [:manufacturer_name, :manufacturer_location], :manufacturers, :name=>:items_manufacturer_name_fkey

    String :manufacturer_name, :size => 50
    String :manufacturer_location
    TrueClass :in_stock, :default => false
    String :name, :default => "John"
    Float  :price, :default => 0

    constraint :pos_id, Sequel.expr(:id) > 0

    index [:manufacturer_name, :manufacturer_location], :name=>:name, :unique=>true
    index [:manufacturer_name], :name=>:manufacturer_name
  end

  db.create_table :newline_tests do
    Integer :abcde_fghi_id
    Integer :jkl_mnopqr_id
    constraint(:valid_stuvw_xyz0, Sequel.case({{:abcde_fghi_id=>[5,6]}=>Sequel.~(:jkl_mnopqr_id=>nil)}, :jkl_mnopqr_id=>nil))
  end

  db.create_table :fk_tests do
    primary_key :id
    Integer :b, :unique=>true, :unique_constraint_name=>'fk_tests_b_uidx'
    foreign_key :c, :fk_tests, :key=>:b, :foreign_key_constraint_name=>'fk_tests_c_fk'
  end
end

DB.run <<SQL
CREATE FUNCTION valid_price() RETURNS trigger AS $emp_stamp$
    BEGIN
        -- Check that empname and salary are given
        IF NEW.price > 1000000 THEN
            RAISE EXCEPTION 'price is too high';
        END IF;
        RETURN NEW;
    END;
$emp_stamp$ LANGUAGE plpgsql;
SQL

DB.run <<SQL
CREATE TRIGGER valid_price BEFORE INSERT OR UPDATE ON items
    FOR EACH ROW EXECUTE PROCEDURE valid_price();
SQL

DB.run "CREATE DOMAIN test_domain AS text"

DB.create_table :domain_tests do
  primary_key :id
  test_domain :test_column
end

DB.create_table :comment_tests do
  primary_key :id
  String :name
end

DB.run "COMMENT ON COLUMN comment_tests.name IS 'name column comment'"
DB.run "COMMENT ON TABLE comment_tests IS 'comment_tests table comment'"

Minitest.after_run do
  DB.drop_table(:items, :manufacturers, :categories, :domain_tests, :comment_tests)
  DB.run "DROP DOMAIN test_domain"
  DB.drop_function(:valid_price)
end

class ::Item < Sequel::Model; end
class ::Category < Sequel::Model; end
class ::Manufacturer < Sequel::Model; end
class ::DomainTest < Sequel::Model; end
class ::CommentTest < Sequel::Model; end
class ::FkTest < Sequel::Model; end
class ::SItem < Sequel::Model(SDB[:items]); end
class ::SItemWithFrozenLiteral < Sequel::Model(SDB[:items]); end
class ::SItemWithCoding < Sequel::Model(SDB[:items]); end
class ::SItemWithEncoding < Sequel::Model(SDB[:items]); end
class ::SItemWithWarnIndent < Sequel::Model(SDB[:items]); end
class ::SItemWithWarnPastScope < Sequel::Model(SDB[:items]); end
class ::SItemWithMagicComment < Sequel::Model(SDB[:items]); end
class ::SCategory < Sequel::Model(SDB[:categories]); end
class ::SManufacturer < Sequel::Model(SDB[:manufacturers]); end
class ::SFkTest < Sequel::Model(SDB[:fk_tests]); end
class ::NewlineTest < Sequel::Model; end
class ::QualifiedTableNameTest < Sequel::Model(Sequel.qualify(:public, :categories)); end
class SComplexDataset < Sequel::Model(SDB[:items].left_join(:categories, :id => :category_id).select{items[:name]}); end
class SErrorDataset < Sequel::Model(:items)
  def self.dataset; raise Sequel::Error; end
end
class ::AccessorItm < Sequel::Model(DB[:items])
  one_to_many :o2m_tcls, class: AccessorItm
  one_to_many :o2m_scls, class: 'AccessorItm'
  many_to_one :m2o, class: AccessorItm
  many_to_one :accessor_itm
  many_to_many :m2mothers, class: AccessorItm
end

# Abstract Base Class
ABC = Class.new(Sequel::Model)

module ModelNamespace
  Model = Class.new(Sequel::Model)
  Model.def_Model(self)
  class Itms < Model(:items); end
end

describe Sequel::Annotate do
  def fix_pg_comment(comment)
    if DB.server_version >= 100002 && (Sequel::MAJOR > 5 || (Sequel::MAJOR == 5 && Sequel::MINOR >= 7))
      comment = comment.sub(/DEFAULT nextval\('[a-z]+_id_seq'::regclass\)/, 'GENERATED BY DEFAULT AS IDENTITY')
    end
    if DB.server_version >= 120000
      comment = comment.gsub(/FOR EACH ROW EXECUTE PROCEDURE/, 'FOR EACH ROW EXECUTE FUNCTION')
    end
    comment
  end

  def fix_sqlite_comment(comment)
    if SDB.sqlite_version >= 33700
      comment = comment.gsub('INTEGER', 'integer')
    end
    comment
  end

  before do
    Dir.mkdir('spec/tmp') unless File.directory?('spec/tmp')
  end
  after do
    Dir['spec/tmp/*.rb'].each{|f| File.delete(f)}
  end

  it "skips files with the sequel-annotate magic comment set to false" do
    FileUtils.cp('spec/unannotated/sitemwithmagiccomment.rb', 'spec/tmp/')
    Sequel::Annotate.annotate(['spec/tmp/sitemwithmagiccomment.rb'])
    File.read('spec/tmp/sitemwithmagiccomment.rb').must_equal File.read('spec/unannotated/sitemwithmagiccomment.rb')
  end

  it "skips files with a class that doesn't descend from Sequel::Model when using :namespace=>true" do
    require './spec/unannotated/non_sequel.rb'
    FileUtils.cp('spec/unannotated/non_sequel.rb', 'spec/tmp/')
    Sequel::Annotate.annotate(['spec/tmp/non_sequel.rb'], :namespace=>true)
    File.read('spec/tmp/non_sequel.rb').must_equal File.read('spec/unannotated/non_sequel.rb')
  end

  it "skips files without a class when using :namespace=>true" do
    require './spec/unannotated/no_class.rb'
    FileUtils.cp('spec/unannotated/no_class.rb', 'spec/tmp/')
    Sequel::Annotate.annotate(['spec/tmp/no_class.rb'], :namespace=>true)
    File.read('spec/tmp/no_class.rb').must_equal File.read('spec/unannotated/no_class.rb')
  end

  it "#schema_info should not return sections we set to false" do
    Sequel::Annotate.new(Item).schema_comment(:indexes => false, :constraints => false, :foreign_keys => false, :triggers => false).must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: items
# Columns:
#  id                    | integer               | PRIMARY KEY DEFAULT nextval('items_id_seq'::regclass)
#  category_id           | integer               | NOT NULL
#  manufacturer_name     | character varying(50) |
#  manufacturer_location | text                  |
#  in_stock              | boolean               | DEFAULT false
#  name                  | text                  | DEFAULT 'John'::text
#  price                 | double precision      | DEFAULT 0
OUTPUT

    Sequel::Annotate.new(Category).schema_comment(:references => false).must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: categories
# Columns:
#  id   | integer | PRIMARY KEY DEFAULT nextval('categories_id_seq'::regclass)
#  name | text    | NOT NULL
# Indexes:
#  categories_pkey     | PRIMARY KEY btree (id)
#  categories_name_key | UNIQUE btree (name)
OUTPUT
  end

  it "#schema_info should return a border if we want one" do
    Sequel::Annotate.new(Item).schema_comment(:border => true, :indexes => false, :constraints => false, :foreign_keys => false, :triggers => false).gsub(/----+/, '---').must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: items
# ---
# Columns:
#  id                    | integer               | PRIMARY KEY DEFAULT nextval('items_id_seq'::regclass)
#  category_id           | integer               | NOT NULL
#  manufacturer_name     | character varying(50) |
#  manufacturer_location | text                  |
#  in_stock              | boolean               | DEFAULT false
#  name                  | text                  | DEFAULT 'John'::text
#  price                 | double precision      | DEFAULT 0
# ---
OUTPUT
  end

  it "#schema_info should return the model schema comment" do
    Sequel::Annotate.new(Item).schema_comment.must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: items
# Columns:
#  id                    | integer               | PRIMARY KEY DEFAULT nextval('items_id_seq'::regclass)
#  category_id           | integer               | NOT NULL
#  manufacturer_name     | character varying(50) |
#  manufacturer_location | text                  |
#  in_stock              | boolean               | DEFAULT false
#  name                  | text                  | DEFAULT 'John'::text
#  price                 | double precision      | DEFAULT 0
# Indexes:
#  items_pkey        | PRIMARY KEY btree (id)
#  name              | UNIQUE btree (manufacturer_name, manufacturer_location)
#  manufacturer_name | btree (manufacturer_name)
# Check constraints:
#  pos_id | (id > 0)
# Foreign key constraints:
#  items_category_id_fkey       | (category_id) REFERENCES categories(id)
#  items_manufacturer_name_fkey | (manufacturer_name, manufacturer_location) REFERENCES manufacturers(name, location)
# Triggers:
#  valid_price | BEFORE INSERT OR UPDATE ON items FOR EACH ROW EXECUTE PROCEDURE valid_price()
OUTPUT

    Sequel::Annotate.new(SComplexDataset).schema_comment.must_equal("")
    Sequel::Annotate.new(SErrorDataset).schema_comment.must_equal("")
    Sequel::Annotate.new(Category).schema_comment.must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: categories
# Columns:
#  id   | integer | PRIMARY KEY DEFAULT nextval('categories_id_seq'::regclass)
#  name | text    | NOT NULL
# Indexes:
#  categories_pkey     | PRIMARY KEY btree (id)
#  categories_name_key | UNIQUE btree (name)
# Referenced By:
#  items | items_category_id_fkey | (category_id) REFERENCES categories(id)
OUTPUT

    Sequel::Annotate.new(Manufacturer).schema_comment.must_equal((<<OUTPUT).chomp)
# Table: manufacturers
# Primary Key: (name, location)
# Columns:
#  name     | text |
#  location | text |
# Indexes:
#  manufacturers_pkey | PRIMARY KEY btree (name, location)
# Referenced By:
#  items | items_manufacturer_name_fkey | (manufacturer_name, manufacturer_location) REFERENCES manufacturers(name, location)
OUTPUT

    Sequel::Annotate.new(NewlineTest).schema_comment.must_equal((<<OUTPUT).chomp)
# Table: newline_tests
# Columns:
#  abcde_fghi_id | integer |
#  jkl_mnopqr_id | integer |
# Check constraints:
#  valid_stuvw_xyz0 | (
#    CASE
#        WHEN abcde_fghi_id = ANY (ARRAY[5, 6]) THEN jkl_mnopqr_id IS NOT NULL
#        ELSE jkl_mnopqr_id IS NULL
#    END)
OUTPUT

    fix_sqlite_comment(Sequel::Annotate.new(SItem).schema_comment).must_equal((<<OUTPUT).chomp)
# Table: items
# Columns:
#  id                    | integer          | PRIMARY KEY AUTOINCREMENT
#  category_id           | integer          | NOT NULL
#  manufacturer_name     | varchar(50)      |
#  manufacturer_location | varchar(255)     |
#  in_stock              | boolean          | DEFAULT 0
#  name                  | varchar(255)     | DEFAULT 'John'
#  price                 | double precision | DEFAULT 0
# Indexes:
#  manufacturer_name | (manufacturer_name)
#  name              | UNIQUE (manufacturer_name, manufacturer_location)
# Foreign key constraints:
#  (category_id) REFERENCES categories
#  (manufacturer_name, manufacturer_location) REFERENCES manufacturers
OUTPUT

    fix_sqlite_comment(Sequel::Annotate.new(SItem).schema_comment(:indexes=>false, :foreign_keys=>false)).must_equal((<<OUTPUT).chomp)
# Table: items
# Columns:
#  id                    | integer          | PRIMARY KEY AUTOINCREMENT
#  category_id           | integer          | NOT NULL
#  manufacturer_name     | varchar(50)      |
#  manufacturer_location | varchar(255)     |
#  in_stock              | boolean          | DEFAULT 0
#  name                  | varchar(255)     | DEFAULT 'John'
#  price                 | double precision | DEFAULT 0
OUTPUT

    fix_sqlite_comment(Sequel::Annotate.new(SCategory).schema_comment).must_equal((<<OUTPUT).chomp)
# Table: categories
# Columns:
#  id   | integer      | PRIMARY KEY AUTOINCREMENT
#  name | varchar(255) | NOT NULL
# Indexes:
#  categories_name_key | UNIQUE (name)
OUTPUT

    fix_sqlite_comment(Sequel::Annotate.new(SManufacturer).schema_comment).must_equal((<<OUTPUT).chomp)
# Table: manufacturers
# Primary Key: (name, location)
# Columns:
#  name     | varchar(255) |
#  location | varchar(255) |
OUTPUT

    Sequel::Annotate.new(QualifiedTableNameTest).schema_comment.must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: public.categories
# Columns:
#  id   | integer | PRIMARY KEY DEFAULT nextval('categories_id_seq'::regclass)
#  name | text    | NOT NULL
# Indexes:
#  categories_pkey     | PRIMARY KEY btree (id)
#  categories_name_key | UNIQUE btree (name)
# Referenced By:
#  items | items_category_id_fkey | (category_id) REFERENCES categories(id)
OUTPUT

    Sequel::Annotate.new(DomainTest).schema_comment.must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: domain_tests
# Columns:
#  id          | integer     | PRIMARY KEY DEFAULT nextval('categories_id_seq'::regclass)
#  test_column | test_domain |
# Indexes:
#  domain_tests_pkey | PRIMARY KEY btree (id)
OUTPUT

    Sequel::Annotate.new(CommentTest).schema_comment.must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: comment_tests
# Comment: comment_tests table comment
# Columns:
#  id   | integer | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY |
#  name | text    |                                              | name column comment
# Indexes:
#  comment_tests_pkey | PRIMARY KEY btree (id)
OUTPUT

    Sequel::Annotate.new(CommentTest).schema_comment(:comments=>false).must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: comment_tests
# Columns:
#  id   | integer | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  name | text    |
# Indexes:
#  comment_tests_pkey | PRIMARY KEY btree (id)
OUTPUT

    Sequel::Annotate.new(FkTest).schema_comment.must_equal(fix_pg_comment((<<OUTPUT).chomp))
# Table: fk_tests
# Columns:
#  id | integer | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  b  | integer |
#  c  | integer |
# Indexes:
#  fk_tests_pkey   | PRIMARY KEY btree (id)
#  fk_tests_b_uidx | UNIQUE btree (b)
# Foreign key constraints:
#  fk_tests_c_fk | (c) REFERENCES fk_tests(b)
# Referenced By:
#  fk_tests | fk_tests_c_fk | (c) REFERENCES fk_tests(b)
OUTPUT

    fix_sqlite_comment(Sequel::Annotate.new(SFkTest).schema_comment).split("\n").reject{|l| l =~ /Indexes|sqlite_autoindex/}.join("\n").must_equal((<<OUTPUT).chomp)
# Table: fk_tests
# Columns:
#  id | integer | PRIMARY KEY AUTOINCREMENT
#  b  | integer |
#  c  | integer |
# Foreign key constraints:
#  (c) REFERENCES fk_tests(b)
OUTPUT
  end

  it "#annotate should append the schema comment if current schema comment is not at the end of the file" do
    FileUtils.cp('spec/unannotated/sitemwithcoding.rb', 'spec/tmp')
    Sequel::Annotate.new(SItemWithCoding).annotate("spec/tmp/sitemwithcoding.rb", :position=>:before)
    Sequel::Annotate.new(SItemWithCoding).annotate("spec/tmp/sitemwithcoding.rb")
    fix_sqlite_comment(File.read("spec/tmp/sitemwithcoding.rb")).strip.must_equal File.read("spec/annotated_both/sitemwithcoding.rb").strip
  end

  [['without options', 'after', []], ['with :position=>:before option', 'before', [{:position=>:before}]]].each do |desc, pos, args|
    it "#annotate #{desc} should annotate the file comment" do
      FileUtils.cp(Dir['spec/unannotated/*.rb'], 'spec/tmp')

      [Item, Category, Manufacturer, SItem, SCategory, SManufacturer, SItemWithFrozenLiteral, SItemWithCoding, SItemWithEncoding, SItemWithWarnIndent, SItemWithWarnPastScope, SComplexDataset].each do |model|
        filename = model.name.downcase
        2.times do
          Sequel::Annotate.new(model).annotate("spec/tmp/#{filename}.rb", *args)
          expected = File.read("spec/annotated_#{pos}/#{filename}.rb")
          if model.db == DB
            File.read("spec/tmp/#{filename}.rb").must_equal fix_pg_comment(expected)
          else
            fix_sqlite_comment(File.read("spec/tmp/#{filename}.rb")).must_equal expected
          end
        end
      end
    end

    it ".annotate #{desc} should annotate all files given" do
      FileUtils.cp(Dir['spec/unannotated/*.rb'], 'spec/tmp')

      2.times do
        Sequel::Annotate.annotate(Dir["spec/tmp/*.rb"], *args)
        [Item, Category, Manufacturer, SItem, SCategory, SManufacturer, SItemWithFrozenLiteral, SItemWithCoding, SItemWithEncoding, SItemWithWarnIndent, SItemWithWarnPastScope, SComplexDataset].each do |model|
          filename = model.name.downcase
          expected = File.read("spec/annotated_#{pos}/#{filename}.rb")
          if model.db == DB
            File.read("spec/tmp/#{filename}.rb").must_equal fix_pg_comment(expected)
          else
            fix_sqlite_comment(File.read("spec/tmp/#{filename}.rb")).must_equal expected
          end
        end
      end
    end
  end

  it ".annotate #{desc} should handle :namespace option" do
    FileUtils.cp('spec/namespaced/itm_unannotated.rb', 'spec/tmp/')
    Sequel::Annotate.annotate(["spec/tmp/itm_unannotated.rb"], :namespace=>'ModelNamespace')
    File.read("spec/tmp/itm_unannotated.rb").must_equal fix_pg_comment(File.read('spec/namespaced/itm_annotated.rb'))
    Sequel::Annotate.annotate(["spec/tmp/itm_unannotated.rb"], :namespace=>'ModelNamespace', :border=>true)
    Sequel::Annotate.annotate(["spec/tmp/itm_unannotated.rb"], :namespace=>'ModelNamespace')
    File.read("spec/tmp/itm_unannotated.rb").must_equal fix_pg_comment(File.read('spec/namespaced/itm_annotated.rb'))
  end

  it ".annotate #{desc} should handle :namespace => true option" do
    FileUtils.cp('spec/namespaced/itm_unannotated.rb', 'spec/tmp')
    Sequel::Annotate.annotate(["spec/tmp/itm_unannotated.rb"], :namespace=>true)
    File.read("spec/tmp/itm_unannotated.rb").must_equal fix_pg_comment(File.read('spec/namespaced/itm_annotated.rb'))
  end

  it ".annotate #{desc} adds inline YARD docs if `sequel-annotate: accessors` is present" do
    FileUtils.cp('spec/accessors/itm_unannotated.rb', 'spec/tmp/')
    Sequel::Annotate.annotate(["spec/tmp/itm_unannotated.rb"])
    puts File.read("spec/tmp/itm_unannotated.rb")
    File.read("spec/tmp/itm_unannotated.rb").must_equal fix_pg_comment(File.read('spec/accessors/itm_annotated.rb'))
  end
end
