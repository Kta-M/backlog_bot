#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Description:
#   Backlogの課題更新監視

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# cron
cronJob = require('cron').CronJob

#----------------------------------------------------------------------
# デバッグフラグ
IS_DEBUG     = false

# 環境変数のパラメータインデックス
CHANNEL         = 0   # チャンネル名
MAX_MSG_LENGTH  = 1   # メッセージの最大文字数
API_KEY         = 2   # APIキー
SPACE_KEY       = 3   # Backlogのスペース名
PROJECT_KEY     = 4   # Backlogのプロジェクト名(可変長で複数可)

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
  api_key   = setting[API_KEY]
  PROJECT_SETTINGS[space_key] = PROJECT_SETTINGS[space_key] or {}
  PROJECT_SETTINGS[space_key][api_key] = PROJECT_SETTINGS[space_key][api_key] or {}
  PROJECT_SETTINGS[space_key][api_key][channel] = {max_msg_len: setting[MAX_MSG_LENGTH], prj_key: []}
  for prj_key, idx in setting
    continue if idx < PROJECT_KEY
    PROJECT_SETTINGS[space_key][api_key][channel]['prj_key'][idx-PROJECT_KEY] = prj_key

console.log PROJECT_SETTINGS
for space_key, space_val of PROJECT_SETTINGS
  for api_key, api_val of space_val
    console.log api_val

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
  for space_key, space_params of PROJECT_SETTINGS
    for api_key, api_params of space_params
      load_space_params(robot, space_key, api_key)
      set_last_id(robot, space_key, api_key, null)

  #--------------------------------------------------------------------
  # スペースのパラメータを再読み込み
  robot.respond /reset_space (.*)/i, (msg) ->
    space_key = msg.match[1]
    
    # スペースキーが見つからなければ終了
    if !PROJECT_SETTINGS[space_key]
      msg.send "reload_space_params: space_key \"#{space_key}\" was not found."
      return

    # スペースが見つからなければ終了
    for api_key, api_params of PROJECT_SETTINGS[space_key]
      if load_space_params(robot, space_key, api_key)
        msg.send "reload_space_params: done for #{space_key}"
      else
        msg.send "reload_space_params: error."
      return
    
    msg.send "reload_space_params: api_key was not found."

  #--------------------------------------------------------------------
  # 最終読み込み位置セット
  robot.respond /set_project_last_id (.*) (.*) (.*)/i, (msg) ->
    space_key = msg.match[1]
    api_key   = msg.match[2]
    new_id    = parseInt(msg.match[3])
    
    # スペースキーが見つからなければ終了
    if !PROJECT_SETTINGS[space_key]
      msg.send "set_project_last_id: space_key \"#{space_key}\" was not found."
      return
    
    # apiキーを検索
    if !PROJECT_SETTINGS[space_key][api_key]
      msg.send "set_project_last_id: api_key \"#{api_key}\" was not found."
      return

    # 指定されたスペースに対して読み込み位置を設定
    if set_last_id(robot, space_key, api_key, new_id)
      msg.send "set_project_last_id: done for \"#{space_key}\" / \"#{api_key}\" / #{new_id}"
    else
      msg.send "set_project_last_id: error."

  #--------------------------------------------------------------------
  # cron登録
  second = 0
  for sk, sv of PROJECT_SETTINGS
    for ak, av of sv
      second = ((second + 5) % 60) + Math.floor((second + 5) / 60)
      second = '*' if IS_DEBUG
      
      # 毎分確認
      cronjob = new cronJob({
        cronTime: "#{second} * * * * *",
        start: true,
        context: {robot: robot, space_key: sk, api_key: ak},
        onTick: cron_func
      })

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# cronで呼び出されるメソッド
cron_func = () ->
  robot     = this.robot
  space_key = this.space_key
  api_key   = this.api_key 

  console.log("cron_exec [#{api_key[0..5]}] > space: #{space_key} / api: #{api_key}")
  
  # 最近の更新を取得
  request = robot.http("https://#{space_key}.backlog.jp/api/v2/space/activities")
                      .query('apiKey': api_key)
                      .query('count': 100)
                      .query('activityTypeId[0]': ACTION_TYPE['task_create']['id'])
                      .query('activityTypeId[1]': ACTION_TYPE['task_update']['id'])
                      .query('activityTypeId[2]': ACTION_TYPE['task_comment']['id'])
                      .get()
  request (err, res, body) ->
    json = JSON.parse body
    req_space_key  = res['req']['_headers']['host'].replace(/\.backlog\.jp/, '')
    req_api_key    = res['req']['path'].replace(/\/api\/v2\/space\/activities\?apiKey=/, '').replace(/&count.*/, '')
    req_prj_params = PROJECT_SETTINGS[req_space_key][req_api_key] 

    # 初回は最新のIDを取るだけで終了
    last_id_key = get_last_id_key(req_space_key, req_api_key)
    last_id     = robot.brain.get(last_id_key)
    robot.brain.set(last_id_key, json[5].id) if IS_DEBUG
    if !last_id
      robot.brain.set(last_id_key, json[0].id)
      return

    # 前回更新地点を探す
    last_id_idx = get_last_id_idx(json, last_id)
    console.log("search_last_id [#{api_key[0..5]}] > last_id -> #{last_id} / last_id_idx -> #{last_id_idx}")
    return if !last_id_idx

    # 更新分を表示していく
    for update_idx in [last_id_idx-1..0]
      update_info = json[update_idx]

      # 表示先のチャンネルを取得
      channel = get_channel(update_info, req_prj_params)
      continue if !channel

      # メッセージ送信
      messages = generate_message(robot, update_info, req_space_key, parseInt(req_prj_params[channel]['max_msg_len']))
      if messages
        for message in messages
          robot.messageRoom "##{channel}", message
          console.log("send_message [#{api_key[0..5]}] > #{channel} / #{message[0...20]}")

    # どこまで確認したかを保存しておく
    last_id_key = get_last_id_key(req_space_key, api_key)
    robot.brain.set(last_id_key, json[0].id)

#----------------------------------------------------------------------
# 前回更新地点を取得
get_last_id_idx = (json, last_id) ->

  for update_info, update_idx in json
    if update_info.id == last_id
      return update_idx

  return null

#----------------------------------------------------------------------
# 表示先のチャンネルを取得
get_channel = (update_info, prj_info) ->

  update_info_prj_key = update_info['project']['projectKey']
  for channel, prj_params of prj_info
    for prj_key in prj_params['prj_key']
      if prj_key == update_info_prj_key
        return channel 

  return null

#----------------------------------------------------------------------
# 更新タイプに対応するメッセージがあればメッセージ作成
# 現状では課題関連の更新のみ対応
generate_message = (robot, update_info, space_key, max_msg_len) -> 

  # 更新タイプ
  action_type_id = parseInt(update_info.type)
  action_message = search_action_message(action_type_id)
  return null if !action_message

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

  full_message = body
  message += "> #{body[0...max_msg_len].replace(/\n/g, '\n> ')}"
  message += "..." if body.length > max_msg_len

  # 状態更新
  if action_type_id == ACTION_TYPE['task_update']['id']
    for change in update_info.content.changes
      switch change.field
        when 'status'
          message += "\n> [状態: #{search_task_status_name(JSON.parse(robot.brain.get(get_task_status_key(space_key))), parseInt(change.new_value))}]"
        when 'resolution'
          message += "\n> [完了理由: #{search_task_resolution_name(JSON.parse(robot.brain.get(get_task_resolution_key(space_key))), parseInt(change.new_value))}]"
        when 'assigner'
          message += "\n> [担当者: #{change.new_value}]"
        when 'attachment'
          message += "\n> [添付ファイル: #{change.new_value}]"
        when 'description'
          message += "\n> [変更内容]\n"
          message += "> #{change.new_value[0...max_msg_len].replace(/\n/g, '\n> ')}"
          message += "> ..." if change.new_value.length > max_msg_len
          full_message = change.new_value
        else
          message += "\n> [#{change.field}: #{change.new_value}]"

  messages = [message]

  # 全文表示の場合は以降の文章を小分けにして送信
  # 送信順に表示されないようなので一旦ナシで
  # full_length = full_message.length
  # if is_full_message && full_length > max_msg_len
    # for idx in [1..Math.floor(full_length / max_msg_len)]
      # begin = max_msg_len * idx
      # end   = max_msg_len * (idx+1)
      # messages[idx] = "> #{body[begin...end].replace(/\n/g, '\n> ')}"

  return messages

#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# スペースの各種パラメータを読み込み
load_space_params = (robot, space_key, api_key) ->

  # ステータスを取得
  request = robot.http("https://#{space_key}.backlog.jp/api/v2/statuses")
                      .query(apiKey: api_key)
                      .get()
  request (err, res, body) ->
    console.log("load_space_params > #{space_key} / #{api_key} / #{body}")
    robot.brain.set(get_task_status_key(space_key), body)

  # 完了理由を取得
  request = robot.http("https://#{space_key}.backlog.jp/api/v2/resolutions")
                      .query(apiKey: api_key)
                      .get()
  request (err, res, body) ->
    console.log("load_space_params > #{space_key} / #{api_key} / #{body}")
    robot.brain.set(get_task_resolution_key(space_key), body)

  return true

#----------------------------------------------------------------------
# 最終読み込み位置を設定
set_last_id = (robot, space_key, api_key, new_id) ->
  robot.brain.set(get_last_id_key(space_key, api_key), new_id)
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
get_last_id_key = (space_key, api_key) ->
  return "backlog_last_id_#{space_key}_#{api_key}"

# ステータスのキー
get_task_status_key = (space_key) ->
  return "backlog_task_status_key_#{space_key}"

# 完了理由のキー
get_task_resolution_key = (space_key) ->
  return "backlog_task_resolution_key_#{space_key}"
