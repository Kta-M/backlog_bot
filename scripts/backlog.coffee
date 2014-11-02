# Description:
#   Backlogの課題更新監視

cronJob = require('cron').CronJob

module.exports = (robot) ->

  # 環境変数
  space_key = process.env.BACKLOG_SPACE_KEY
  api_key   = process.env.BACKLOG_API_KEY
  channel   = process.env.BACKLOG_SEND_CHANNEL
  
  # 更新タイプ
  ACTION_TYPE =
    task_create  : 1
    task_update  : 2
    task_comment : 3
    max          : 3

  # 各更新タイプに対するメッセージ
  ACTION_MESSAGE = ['課題を追加しました。',
                    '課題を更新しました。',
                    '課題にコメントしました。']

  # 課題のステータス
  TASK_STATUS = null

  # リセット
  robot.respond /reset/i, (msg) ->
    last_id_key = "#backlog_last_id_#{space_key}"
    robot.brain.set last_id_key, null
    msg.send "reset: done"

  # 毎分確認
  cronjob = new cronJob('0 * * * * *', () =>

    # 状態一覧を取得しておく
    if TASK_STATUS == null
      request = robot.http("https://#{space_key}.backlog.jp/api/v2/statuses")
                          .query(apiKey: api_key)
                          .get()
      request (err, res, body) ->
        TASK_STATUS = JSON.parse body

    # 最近の更新を取得(デフォルトで20件：1分ごとに確認するのでこれで問題ないと思う)
    request = robot.http("https://#{space_key}.backlog.jp/api/v2/space/activities")
                        .query(apiKey: api_key)
                        .get()
    request (err, res, body) ->
      json = JSON.parse body
      
      # 初回は最新のIDを取るだけで終了
      last_id_key = "#backlog_last_id_#{space_key}"
      last_id     = robot.brain.get last_id_key
      if last_id == null
        robot.brain.set last_id_key, json[5].id   # テスト用に一旦5にしておく
        return

      # 前回更新地点を探す
      last_id_idx = 0
      for update_info, idx in json
        if update_info.id == last_id
          last_id_idx = idx
          break

      # 更新なしなら終了
      return if last_id_idx == 0

      # 更新分を表示していく
      for idx in [last_id_idx-1..0]

        # 更新タイプ
        action_type = json[idx].type

        # 課題の更新のみ取得
        if action_type <= ACTION_TYPE.max
          # ユーザー名、更新タイプ
          message =  "#{json[idx].createdUser.name}さんが#{ACTION_MESSAGE[action_type-1]}\n"

          # URL
          message += "> https://#{space_key}.backlog.jp/view/#{json[idx].project.projectKey}-#{json[idx].content.key_id}"
          message += "#comment-#{json[idx].content.id}" if action_type == ACTION_TYPE.task_update || action_type == ACTION_TYPE.task_comment
          message += "\n"

          # 課題タイトル
          message += "> *#{json[idx].content.summary}*\n"

          # 本文
          if action_type == ACTION_TYPE.task_create
            body = json[idx].content.description
          else
            body = json[idx].content.comment.content
          message += "> #{body[0..100].replace(/\n/g, '\n> ')}"
          message += "..." if body.length > 100

          # 状態更新
          if action_type == ACTION_TYPE.task_update
            for change in json[idx].content.changes
              switch change.field
                when 'status'
                  # ステータス名の取り方は手抜き
                  message += "\n> [状態: #{TASK_STATUS[parseInt(change.new_value)-1].name}]"
                when 'assigner'
                  message += "\n> [担当者: #{change.new_value}]"
                else
                  message += "\n> [#{change.field}: #{change.new_value}]"

          # メッセージ送信
          envelope = room: channel
          robot.send envelope, message

      # どこまで確認したかを保存しておく
      robot.brain.set last_id_key, json[0].id

  )
  cronjob.start()
