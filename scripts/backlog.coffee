# Description:
#   Backlogの課題更新監視

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# cron
cronJob = require('cron').CronJob

#----------------------------------------------------------------------
# 環境変数
SPACE_KEYS = process.env.BACKLOG_SPACE_KEYS.split(',')
API_KEYS   = process.env.BACKLOG_API_KEYS.split(',')
CHANNELS   = process.env.BACKLOG_SEND_CHANNELS.split(',')

#----------------------------------------------------------------------
# 更新タイプ
ACTION_TYPE =
  'task_create':
    'id': 1
    'message': '課題を追加しました。'
  'task_update':
    'id': 2
    'message': '課題を更新しました。'
  'task_comment':
    'id': 3
    'message': '課題にコメントしました。'

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# 動作定義
module.exports = (robot) ->

  # 初期化
  for space_key, idx in SPACE_KEYS
    api_key = API_KEYS[idx]
    initialize(robot, space_key, api_key)

  #--------------------------------------------------------------------
  # リセット
  robot.respond /reset (.*)/i, (msg) ->
    space_key = msg.match[1]
    api_key = null
    for s, idx in SPACE_KEYS
      if space_key == s
        api_key = API_KEYS[idx]

    # スペースが見つからなければ終了
    if api_key == null
      msg.send "reset: space_key \"#{space_key}\" was not found."
      return 

    # 指定されたスペースに対して初期化を実行
    initialize(robot, space_key, api_key)
    msg.send "reset: done for #{space_key}"

  #--------------------------------------------------------------------
  # cron登録
  for space_key, space_idx in SPACE_KEYS
    api_key = API_KEYS[space_idx]
    channel = CHANNELS[space_idx]

    # 毎分確認
    cronjob = new cronJob("#{(space_idx*5)%60} * * * * *", () =>

      # 最近の更新を取得(デフォルトで20件：1分ごとに確認するのでこれで問題ないと思う)
      request = robot.http("https://#{space_key}.backlog.jp/api/v2/space/activities")
                          .query(apiKey: api_key)
                          .get()
      request (err, res, body) ->
        json = JSON.parse body
        
        # 初回は最新のIDを取るだけで終了
        last_id_key = get_last_id_key(space_key)
        last_id     = robot.brain.get last_id_key
        if last_id == null
          robot.brain.set last_id_key, json[0].id
          return

        # 前回更新地点を探す
        last_id_idx = 0
        for update_info, update_idx in json
          if update_info.id == last_id
            last_id_idx = update_idx
            break

        # 更新なしなら終了
        return if last_id_idx == 0

        # 更新分を表示していく
        for update_idx in [last_id_idx-1..0]

          update_info = json[update_idx]

          # 更新タイプ
          action_type_id = parseInt(update_info.type)
          action_message = search_action_message(action_type_id)

          # 更新タイプに対応するメッセージがあれば通知
          # 現状では課題関連の更新のみ対応
          if action_message
            # ユーザー名、更新タイプ
            message =  "#{update_info.createdUser.name}さんが#{action_message}\n"

            # URL
            message += "https://#{space_key}.backlog.jp/view/#{update_info.project.projectKey}-#{update_info.content.key_id}"
            message += "#comment-#{update_info.content.comment.id}" if action_type_id == ACTION_TYPE['task_update']['id'] || action_type_id == ACTION_TYPE['task_comment']['id']
            message += "\n"

            # 課題タイトル
            message += "> *#{update_info.content.summary}*\n"

            # 本文
            if action_type_id == ACTION_TYPE['task_create']['id']
              body = update_info.content.description
            else
              body = update_info.content.comment.content
            message += "> #{body[0..100].replace(/\n/g, '\n> ')}"
            message += "..." if body.length > 100

            # 状態更新
            if action_type_id == ACTION_TYPE['task_update']['id']
              for change in update_info.content.changes
                switch change.field
                  when 'status'
                    message += "\n> [状態: #{search_task_status_name(JSON.parse(robot.brain.get(get_task_status_key(space_key))), parseInt(change.new_value))}]"
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

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# 各種パラメータを初期化
initialize = (robot, space_key, api_key) ->

  # 最終取得位置をnullに
  robot.brain.set get_last_id_key(space_key), null

  # ステータスを取得
  request = robot.http("https://#{space_key}.backlog.jp/api/v2/statuses")
                      .query(apiKey: api_key)
                      .get()
  request (err, res, body) ->
    robot.brain.set get_task_status_key(space_key), body

#----------------------------------------------------------------------
# 更新に対するメッセージを取得
search_action_message = (action_type_id) ->
  for key, val of ACTION_TYPE
    return val['message'] if action_type_id == val['id']

  return null

#----------------------------------------------------------------------
# 課題のステータス名を検索
search_task_status_name = (task_status_json, state_id) ->
  return "undefined" if task_status_json == null

  for task_state in task_status_json
    return task_state.name if task_state.id == state_id

  return "undefined"

#----------------------------------------------------------------------

# 最終取得位置のキー
get_last_id_key = (space_key) ->
  return "backlog_last_id_#{space_key}"

# ステータスのキー
get_task_status_key = (space_key) ->
  return "backlog_task_status_key_#{space_key}"
