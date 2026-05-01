class AddSentimentAnalysisFieldsToFacebookCommentModerations < ActiveRecord::Migration[7.1]
  def change
    unless column_exists?(:facebook_comment_moderations, :sentiment_offensive)
      add_column :facebook_comment_moderations, :sentiment_offensive, :boolean, default: false, null: false
    end
    unless column_exists?(:facebook_comment_moderations, :sentiment_confidence)
      add_column :facebook_comment_moderations, :sentiment_confidence, :float, default: 0.0, null: false
    end
    unless column_exists?(:facebook_comment_moderations, :sentiment_reason)
      add_column :facebook_comment_moderations, :sentiment_reason, :text
    end
  end
end

