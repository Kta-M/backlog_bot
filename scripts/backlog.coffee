# Description:
#   Backlogの課題更新監視

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# cron
cronJob = require('cron').CronJob

#----------------------------------------------------------------------
# 環境変数のパラメータインデックス
CHANNEL     = 0
API_KEY     = 1
SPACE_KEY   = 2
PROJECT_KEY = 3

# ここにプロジェクトの設定を格納する
PROJECT_SETTINGS = {}

for env_idx in [0..99]
  # 連番で設定を取得
  setting = process.env["BACKLOG_PROJECT_SETTING_#{('0'+env_idx).slice(-2)}"]

  # 値が入っていなければスキップ
  continue if !setting

  # 要素が足りなければスキップ
  setting = setting.split(',')
  continue if setting.length <= PROJECT_KEY

  # 要素の前後をトリミング
  for val, idx in setting
    setting[idx] = val.trim()

  space_key = setting[SPACE_KEY]
  channel   = setting[CHANNEL]
  PROJECT_SETTINGS[space_key] = PROJECT_SETTINGS[space_key] or {api_key: setting[API_KEY], projects: {}}
  PROJECT_SETTINGS[space_key]['projects'][channel] = []
  for prj_key, idx in setting
    continue if idx < PROJECT_KEY
    PROJECT_SETTINGS[space_key]['projects'][channel][idx-PROJECT_KEY] = prj_key

console.log "-----------------------------------------"
console.log PROJECT_SETTINGS
console.log "-----------------------------------------"

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
  for space_key, params of PROJECT_SETTINGS
    load_space_params(robot, space_key, params['api_key'])
    for channel, prj_ary of params
      initialize_pos(robot, space_key, channel)

  #--------------------------------------------------------------------
  # スペースのパラメータを再読み込み
  robot.respond /reset_space (.*)/i, (msg) ->
    space_key = msg.match[1]
    
    # スペースキーが見つからなければ終了
    if !PROJECT_SETTINGS[space_key]
      msg.send "reload_space_params: space_key \"#{space_key}\" was not found."
      return

    # スペースが見つからなければ終了
    api_key = PROJECT_SETTINGS[space_key]['api_key']
    if !api_key
      msg.send "reload_space_params: api_key was not found."
      return 

    if load_space_params(robot, space_key, api_key)
      msg.send "reload_space_params: done for #{space_key}"
    else
      msg.send "reload_space_params: error."

  #--------------------------------------------------------------------
  # プロジェクトの最終読み込み位置リセット
  robot.respond /reset_project (.*) (.*)/i, (msg) ->
    space_key = msg.match[1]
    channel   = msg.match[2]
    
    # スペースキーが見つからなければ終了
    if !PROJECT_SETTINGS[space_key]
      msg.send "reset_project_pos: space_key \"#{space_key}\" was not found."
      return
    
    # チャンネルが見つからなければ終了
    if !PROJECT_SETTINGS[space_key]['projects'][channel]
      msg.send "reset_project_pos: channel \"#{channel}\" was not found."
      return

    # 指定されたスペースに対して初期化を実行
    if initialize_pos(robot, space_key, channel)
      msg.send "reset_project_pos: done for \"#{space_key} / #{channel}\""
    else
      msg.send "reset_project_pos: error."

  #--------------------------------------------------------------------
  # cron登録
  second = 0
  for sk, prm of PROJECT_SETTINGS
    second = (second + 5) % 60
      
    # 毎分確認
    cronjob = new cronJob({
      cronTime: "#{second} * * * * *",
      start: true,
      context: {space_key: sk},
      onTick: () ->

        space_key = this.space_key
        params    = PROJECT_SETTINGS[space_key]
        api_key   = params['api_key'] 

        # 最近の更新を取得(デフォルトで20件：1分ごとに確認するのでこれで問題ないと思う)
        request = robot.http("https://#{space_key}.backlog.jp/api/v2/space/activities")
                            .query(apiKey: api_key)
                            .get()
        request (err, res, body) ->
          json = JSON.parse body
          req_space_key = res['req']['_headers']['host'].replace(/\.backlog\.jp/, '')
          req_params    = PROJECT_SETTINGS[req_space_key] 

          # 初回は最新のIDを取るだけで終了
          for channel, prj_ary of req_params['projects']
            last_id_key = get_last_id_key(req_space_key, channel)
            last_id     = robot.brain.get last_id_key
            if last_id == null
              robot.brain.set last_id_key, json[5].id
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

            # 表示先のチャンネルを取得
            channel = null
            update_info_prj_key = update_info['project']['projectKey']
            for params_channel, params_prj_ary of req_params['projects']
              for params_prj_key in params_prj_ary
                if params_prj_key == update_info_prj_key
                  channel = params_channel
                  break
            continue if !channel

            # 更新タイプ
            action_type_id = parseInt(update_info.type)
            action_message = search_action_message(action_type_id)

            # 更新タイプに対応するメッセージがあれば通知
            # 現状では課題関連の更新のみ対応
            if action_message
              # ユーザー名、更新タイプ
              message =  "#{update_info.createdUser.name}さんが#{action_message}\n"

              # URL
              message += "https://#{req_space_key}.backlog.jp/view/#{update_info.project.projectKey}-#{update_info.content.key_id}"
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
                      message += "\n> [状態: #{search_task_status_name(JSON.parse(robot.brain.get(get_task_status_key(req_space_key))), parseInt(change.new_value))}]"
                    when 'resolution'
                      message += "\n> [完了理由: #{search_task_resolution_name(JSON.parse(robot.brain.get(get_task_resolution_key(req_space_key))), parseInt(change.new_value))}]"
                    when 'assigner'
                      message += "\n> [担当者: #{change.new_value}]"
                    when 'attachment'
                      message += "\n> [添付ファイル: #{change.new_value}]"
                    when 'description'
                      message += "\n> [変更内容]\n"
                      message += "> #{change.new_value[0..100].replace(/\n/g, '\n> ')}"
                      message += "> ..." if change.new_value.length > 100
                    else
                      message += "\n> [#{change.field}: #{change.new_value}]"

              # メッセージ送信
              robot.messageRoom "##{channel}", message
              console.log message

          # どこまで確認したかを保存しておく
          robot.brain.set last_id_key, json[0].id
    })

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# スペースの各種パラメータを読み込み
load_space_params = (robot, space_key, api_key) ->

  # ステータスを取得
  request = robot.http("https://#{space_key}.backlog.jp/api/v2/statuses")
                      .query(apiKey: api_key)
                      .get()
  request (err, res, body) ->
    robot.brain.set get_task_status_key(space_key), body

  # 完了理由を取得
  request = robot.http("https://#{space_key}.backlog.jp/api/v2/resolutions")
                      .query(apiKey: api_key)
                      .get()
  request (err, res, body) ->
    robot.brain.set get_task_resolution_key(space_key), body

  return true

#----------------------------------------------------------------------
# 最終読み込み位置をnullに
initialize_pos = (robot, space_key, channel) ->
  
  # 最終取得位置をnullに
  robot.brain.set get_last_id_key(space_key, channel), null

  return true

#----------------------------------------------------------------------
# 更新に対するメッセージを取得
search_action_message = (action_type_id) ->
  for key, val of ACTION_TYPE
    return val['message'] if action_type_id == val['id']

  return null

#----------------------------------------------------------------------
# 課題のステータス名を検索
search_task_status_name = (task_status_json, state_id) ->
  return __search_name_by_id(task_status_json, state_id)

# 完了理由のステータス名を検索
search_task_resolution_name = (task_resolution_json, resolution_id) ->
  return __search_name_by_id(task_resolution_json, resolution_id)
  
# idから名前を取得
__search_name_by_id = (json, id) ->
  return "undefined" if json == null

  for val in json
    return val.name if val.id == id

  return "undefined"
  
#----------------------------------------------------------------------

# 最終取得位置のキー
get_last_id_key = (space_key, channel) ->
  return "backlog_last_id_#{space_key}_#{channel}"

# ステータスのキー
get_task_status_key = (space_key) ->
  return "backlog_task_status_key_#{space_key}"

# 完了理由のキー
get_task_resolution_key = (space_key) ->
  return "backlog_task_resolution_key_#{space_key}"
