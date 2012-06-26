require 'soft_deletion'

require 'active_support/test_case'
require 'shoulda'
require 'redgreen'

# connect
ActiveRecord::Base.establish_connection(
  :adapter => "sqlite3",
  :database => ":memory:"
)

# create tables
ActiveRecord::Schema.define(:version => 1) do
  create_table :forums do |t|
    t.integer :category_id
    t.timestamp :deleted_at
  end

  create_table :categories do |t|
    t.timestamp :deleted_at
  end

  create_table :original_categories do |t|
  end
end

class ActiveRecord::Base
  def self.silent_set_table_name(name)
    if ActiveRecord::VERSION::MAJOR > 2
      self.table_name = name
    else
      set_table_name name
    end
  end
end

# setup models
class Forum < ActiveRecord::Base
  include SoftDeletion
  belongs_to :category
end

class Category < ActiveRecord::Base
  include SoftDeletion
  has_many :forums, :dependent => :destroy
end

# No association
class NACategory < ActiveRecord::Base
  silent_set_table_name 'categories'
  include SoftDeletion
end

# Independent association
class IDACategory < ActiveRecord::Base
  silent_set_table_name 'categories'
  include SoftDeletion
  has_many :forums, :dependent => :destroy, :foreign_key => :category_id
end

# Nullified dependent association
class NDACategory < ActiveRecord::Base
  silent_set_table_name 'categories'
  include SoftDeletion
  has_many :forums, :dependent => :destroy, :foreign_key => :category_id
end

# Has ome association
class HOACategory < ActiveRecord::Base
  silent_set_table_name 'categories'
  include SoftDeletion
  has_one :forum, :dependent => :destroy, :foreign_key => :category_id
end

# Class without column deleted_at
class OriginalCategory < ActiveRecord::Base
  include SoftDeletion
end

# Has many destroyable association
class DACategory < ActiveRecord::Base
  silent_set_table_name 'categories'
  include SoftDeletion
  has_many :destroyable_forums, :dependent => :destroy, :foreign_key => :category_id
end

# Forum that isn't soft deletable for association checing
class DestroyableForum < ActiveRecord::Base
  silent_set_table_name 'forums'
end

def clear_callbacks(model, callback)
  if ActiveRecord::VERSION::MAJOR > 2
    model.define_callbacks callback
  else
    model.class_eval{ instance_variable_set "@after_#{callback}_callbacks", nil }
  end
end

class SoftDeletionTest < ActiveSupport::TestCase
  def assert_deleted(resource)
    resource.class.with_deleted do
      resource.reload
      assert resource.deleted?
    end
  end

  def assert_not_deleted(resource)
    resource.reload
    assert !resource.deleted?
  end

  def self.successfully_soft_deletes
    context 'successfully soft deleted' do
      setup do
        @category.soft_delete!
      end

      should 'mark itself as deleted' do
        assert_deleted @category
      end

      should 'soft delete its dependent associations' do
        assert_deleted @forum
      end
    end
  end

  def self.successfully_bulk_soft_deletes
    context 'successfully bulk soft deleted' do
      setup do
        Category.soft_delete_all!(@category)
      end

      should 'mark itself as deleted' do
        assert_deleted @category
      end

      should 'soft delete its dependent associations' do
        assert_deleted @forum
      end
    end
  end

  setup do
    clear_callbacks Category, :soft_delete
  end

  context ".after_soft_delete" do
    should "be called after soft-deletion" do
      Category.after_soft_delete :foo
      category = Category.create!
      category.expects(:foo)
      category.soft_delete!
    end

    should "be called after bulk soft-deletion" do
      Category.after_soft_delete :foo
      category = Category.create!
      category.expects(:foo)
      Category.soft_delete_all!(category)
    end

    should "be call multiple after soft-deletion" do
      Category.after_soft_delete :foo, :bar
      category = Category.create!
      category.expects(:foo)
      category.expects(:bar)
      category.soft_delete!
    end

    should "not be called after normal destroy" do
      Category.after_soft_delete :foo
      category = Category.create!
      category.expects(:foo).never
      category.destroy
    end
  end

  context 'without dependent associations' do
    should 'only soft-delete itself' do
      category = NACategory.create!
      category.soft_delete!
      assert_deleted category
    end
  end

  context 'with independent associations' do
    should 'not delete associations' do
      category = IDACategory.create!
      forum = category.forums.create!
      category.soft_delete!
      assert_deleted forum
    end
  end

  context 'with dependent has_one association' do
    setup do
      @category = HOACategory.create!
      @forum = @category.create_forum
    end

    successfully_soft_deletes
    successfully_bulk_soft_deletes
  end

  context "with dependent association that doesn't have soft deletion" do
    setup do
      @category = DACategory.create!
      @forum = @category.destroyable_forums.create!
    end

    context 'successfully soft deleted' do
      setup do
        @category.soft_delete!
      end

      should 'mark itself as deleted' do
        assert_deleted @category
      end

      should 'not destroy dependent association' do
        assert DestroyableForum.exists?(@forum.id)
      end
    end
  end

  context 'with dependent has_many associations' do
    setup do
      @category = Category.create!
      @forum = @category.forums.create!
    end

    context 'failing to soft delete' do
      setup do
        @category.stubs(:valid?).returns(false)
        assert_raise(ActiveRecord::RecordInvalid) { @category.soft_delete! }
      end

      should 'not mark itself as deleted' do
        assert_not_deleted @category
      end

      should 'not soft delete its dependent associations' do
        assert_not_deleted @forum
      end
    end

    successfully_soft_deletes
    successfully_bulk_soft_deletes

    context 'being restored from soft deletion' do
      setup do
        @category.soft_delete!
        Category.with_deleted do
          @category.reload
          @category.soft_undelete!
          @category.reload
        end
      end

      should 'not mark itself as deleted' do
        assert_not_deleted @category
      end

      should 'restore its dependent associations' do
        assert_not_deleted @forum
      end
    end
  end

  context 'a soft-deleted has-many category that nullifies forum references on delete' do
    should 'nullify those references' do
      category = NDACategory.create!
      forum = category.forums.create!
      category.soft_delete!
      assert_deleted forum
      #assert_nil forum.category_id # TODO
    end
  end

  context 'without deleted_at column' do
    should 'default scope should not provoke an error' do
      assert_nothing_raised do
        OriginalCategory.create!
      end
    end
  end

  context "bulk soft deletion" do
    setup do
      @categories = 2.times.map { Category.create! }
    end

    context "by id" do
      setup do
        Category.soft_delete_all!(@categories.map(&:id))
      end

      should "delete all models" do
        @categories.each do |category|
          assert_deleted category
        end
      end
    end

    context "by model" do
      setup do
        Category.soft_delete_all!(@categories)
      end

      should "delete all models" do
        @categories.each do |category|
          assert_deleted category
        end
      end
    end
  end
end
