local CET6Mod = RegisterMod("CET-6 Vocabulary Must-Learn", 1)
local game = Game()
local words = include("cet6_words")

local ITEM_NAME = "CET6"
local ITEM_DISPLAY_NAME_ZH = "6级单词必背 CET6"
local ITEM_ID = Isaac.GetItemIdByName(ITEM_NAME)

local MIN_QUIZ_FRAMES = 30 * 30
local MAX_QUIZ_FRAMES = 30 * 60
local INPUT_LOCK_FRAMES = 12
local FEEDBACK_FRAMES = 90

local rng = RNG()
local outcomeRng = RNG()
local uiFont = Font()
local panelSprite = Sprite()

local quiz = {
    active = false,
    timer = nil,
    ownerIndex = 0,
    correctSlot = 1,
    correctAnswer = "",
    meaning = "",
    pinyin = "",
    options = {},
    inputLock = 0,
    frozen = {},
}

local feedback = {
    frames = 0,
    text = "",
    answer = "",
    good = false,
}

local REWARD_WEIGHTS = {
    { id = "angel", weight = 1 },
    { id = "treasure", weight = 4 },
    { id = "supplies", weight = 25 },
    { id = "coin", weight = 70 },
}

local PENALTY_WEIGHTS = {
    { id = "delete", weight = 5 },
    { id = "damage", weight = 45 },
    { id = "fly", weight = 50 },
}

local function CopyVector(vector)
    return Vector(vector.X, vector.Y)
end

local function RandomInt(minimum, maximum)
    return minimum + rng:RandomInt(maximum - minimum + 1)
end

local function PickWeightedOutcome(entries, label)
    local roll = outcomeRng:RandomInt(100) + 1
    local cumulative = 0

    for _, entry in ipairs(entries) do
        cumulative = cumulative + entry.weight
        if roll <= cumulative then
            Isaac.ConsoleOutput("CET6 " .. label .. " roll: " .. roll .. "/100 -> " .. entry.id .. "\n")
            return entry.id
        end
    end

    Isaac.ConsoleOutput("CET6 weight table error: " .. label .. "\n")
    return entries[#entries].id
end

local function ResetQuizTimer()
    quiz.timer = RandomInt(MIN_QUIZ_FRAMES, MAX_QUIZ_FRAMES)
end

local function GetItemHolders()
    local holders = {}
    if ITEM_ID <= 0 then
        return holders
    end

    for index = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(index)
        if player:HasCollectible(ITEM_ID) then
            table.insert(holders, index)
        end
    end
    return holders
end

local function CaptureEntity(entity)
    local state = {
        entity = EntityPtr(entity),
        position = CopyVector(entity.Position),
        velocity = CopyVector(entity.Velocity),
    }

    local npc = entity:ToNPC()
    if npc ~= nil then
        state.npcState = npc.State
        state.npcStateFrame = npc.StateFrame
        state.projectileCooldown = npc.ProjectileCooldown
        state.projectileDelay = npc.ProjectileDelay
    end

    local tear = entity:ToTear()
    if tear ~= nil then
        state.height = tear.Height
        state.fallingSpeed = tear.FallingSpeed
        state.fallingAcceleration = tear.FallingAcceleration
    end

    local projectile = entity:ToProjectile()
    if projectile ~= nil then
        state.height = projectile.Height
        state.fallingSpeed = projectile.FallingSpeed
        state.fallingAcceleration = projectile.FallingAccel
    end

    local bomb = entity:ToBomb()
    if bomb ~= nil then
        state.explosionCountdown = bomb.ExplosionCountdown
    end

    local pickup = entity:ToPickup()
    if pickup ~= nil then
        state.timeout = pickup.Timeout
    end

    quiz.frozen[GetPtrHash(entity)] = state
end

local function ApplyFrozenState(entity, state)
    entity.Position = state.position
    entity.Velocity = Vector.Zero

    local npc = entity:ToNPC()
    if npc ~= nil and state.npcState ~= nil then
        npc.State = state.npcState
        npc.StateFrame = state.npcStateFrame
        npc.ProjectileCooldown = state.projectileCooldown
        npc.ProjectileDelay = state.projectileDelay
    end

    local tear = entity:ToTear()
    if tear ~= nil and state.height ~= nil then
        tear.Height = state.height
        tear.FallingSpeed = state.fallingSpeed
        tear.FallingAcceleration = state.fallingAcceleration
    end

    local projectile = entity:ToProjectile()
    if projectile ~= nil and state.height ~= nil then
        projectile.Height = state.height
        projectile.FallingSpeed = state.fallingSpeed
        projectile.FallingAccel = state.fallingAcceleration
    end

    local bomb = entity:ToBomb()
    if bomb ~= nil and state.explosionCountdown ~= nil then
        bomb.ExplosionCountdown = state.explosionCountdown
    end

    local pickup = entity:ToPickup()
    if pickup ~= nil and state.timeout ~= nil then
        pickup.Timeout = state.timeout
    end
end

local function FreezeRoom()
    for _, entity in ipairs(Isaac.GetRoomEntities()) do
        local key = GetPtrHash(entity)
        local state = quiz.frozen[key]

        if state == nil then
            if entity:ToProjectile() ~= nil then
                entity:Remove()
            else
                CaptureEntity(entity)
                state = quiz.frozen[key]
            end
        end

        if state ~= nil and entity:Exists() then
            ApplyFrozenState(entity, state)
        end
    end
end

local function ReleaseRoom()
    for _, state in pairs(quiz.frozen) do
        local entity = state.entity.Ref
        if entity ~= nil and entity:Exists() then
            entity.Position = state.position
            entity.Velocity = state.velocity

            local bomb = entity:ToBomb()
            if bomb ~= nil and state.explosionCountdown ~= nil then
                bomb.ExplosionCountdown = state.explosionCountdown
            end

            local pickup = entity:ToPickup()
            if pickup ~= nil and state.timeout ~= nil then
                pickup.Timeout = state.timeout
            end
        end
    end
    quiz.frozen = {}
end

local function MakeQuestion()
    local correctIndex = RandomInt(1, #words)
    local chosen = { [correctIndex] = true }
    local candidates = { correctIndex }

    while #candidates < 3 do
        local index = RandomInt(1, #words)
        if not chosen[index] then
            chosen[index] = true
            table.insert(candidates, index)
        end
    end

    for i = #candidates, 2, -1 do
        local j = RandomInt(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end

    quiz.meaning = words[correctIndex].meaning
    quiz.pinyin = words[correctIndex].pinyin
    quiz.correctAnswer = words[correctIndex].word
    quiz.options = {}
    for slot = 1, 3 do
        quiz.options[slot] = words[candidates[slot]].word
        if candidates[slot] == correctIndex then
            quiz.correctSlot = slot
        end
    end
end

local function BeginQuiz(ownerIndex)
    quiz.active = true
    quiz.ownerIndex = ownerIndex
    quiz.inputLock = INPUT_LOCK_FRAMES
    quiz.frozen = {}
    MakeQuestion()

    for _, entity in ipairs(Isaac.GetRoomEntities()) do
        CaptureEntity(entity)
    end
end

local function FindSpawnPosition(player, angle, distance)
    local room = game:GetRoom()
    local target = player.Position + Vector.FromAngle(angle):Resized(distance)
    return room:FindFreePickupSpawnPosition(target, 20, true)
end

local function SpawnPickup(player, variant, subtype, angle)
    Isaac.Spawn(
        EntityType.ENTITY_PICKUP,
        variant,
        subtype,
        FindSpawnPosition(player, angle, 45),
        Vector.Zero,
        player
    )
end

local function SpawnPoolItem(player, poolType)
    local itemId = game:GetItemPool():GetCollectible(
        poolType,
        true,
        rng:Next(),
        CollectibleType.COLLECTIBLE_BREAKFAST
    )
    SpawnPickup(player, PickupVariant.PICKUP_COLLECTIBLE, itemId, -90)
end

local function DeleteRandomCollectible(player)
    local candidates = {}
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()

    for itemId = 1, collectibleList.Size - 1 do
        local config = itemConfig:GetCollectible(itemId)
        if config ~= nil
            and not config:HasTags(ItemConfig.TAG_QUEST)
            and player:GetCollectibleNum(itemId, true) > 0 then
            for _ = 1, player:GetCollectibleNum(itemId, true) do
                table.insert(candidates, itemId)
            end
        end
    end

    if #candidates == 0 then
        return false
    end

    local itemId = candidates[RandomInt(1, #candidates)]
    local config = itemConfig:GetCollectible(itemId)

    if config ~= nil and config.Type == ItemType.ITEM_ACTIVE then
        for slot = ActiveSlot.SLOT_PRIMARY, ActiveSlot.SLOT_POCKET2 do
            if player:GetActiveItem(slot) == itemId then
                player:RemoveCollectible(itemId, true, slot, true)
                return true
            end
        end
    end

    player:RemoveCollectible(itemId, true, ActiveSlot.SLOT_PRIMARY, true)
    return true
end

local function SpawnHarmlessGrayFly(player)
    local fly = Isaac.Spawn(
        EntityType.ENTITY_ATTACKFLY,
        0,
        0,
        FindSpawnPosition(player, 0, 65),
        Vector.Zero,
        player
    ):ToNPC()

    if fly ~= nil then
        fly.CollisionDamage = 0
        fly.Color = Color(0.48, 0.48, 0.48, 1.0, 0, 0, 0)
    end
end

local function ApplyCorrectReward(player)
    local outcome = PickWeightedOutcome(REWARD_WEIGHTS, "reward")
    if outcome == "angel" then
        SpawnPoolItem(player, ItemPoolType.POOL_ANGEL)
        feedback.text = "CORRECT! Angel item (1%)"
    elseif outcome == "treasure" then
        SpawnPoolItem(player, ItemPoolType.POOL_TREASURE)
        feedback.text = "CORRECT! Treasure item (4%)"
    elseif outcome == "supplies" then
        SpawnPickup(player, PickupVariant.PICKUP_BOMB, BombSubType.BOMB_NORMAL, 210)
        SpawnPickup(player, PickupVariant.PICKUP_KEY, KeySubType.KEY_NORMAL, 270)
        SpawnPickup(player, PickupVariant.PICKUP_LIL_BATTERY, BatterySubType.BATTERY_NORMAL, 330)
        feedback.text = "CORRECT! Bomb + Key + Battery (25%)"
    else
        SpawnPickup(player, PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, -90)
        feedback.text = "CORRECT! Penny (70%)"
    end
    player:AnimateHappy()
    feedback.answer = ""
    feedback.good = true
end

local function ApplyWrongPenalty(player, correctAnswer)
    local outcome = PickWeightedOutcome(PENALTY_WEIGHTS, "penalty")
    if outcome == "delete" then
        local deleted = DeleteRandomCollectible(player)
        feedback.text = deleted and "WRONG! One item was deleted (5%)" or "WRONG! No removable item"
    elseif outcome == "damage" then
        player:TakeDamage(
            1,
            DamageFlag.DAMAGE_INVINCIBLE | DamageFlag.DAMAGE_NO_MODIFIERS,
            EntityRef(player),
            0
        )
        game:GetLevel():SetRedHeartDamage()
        feedback.text = "WRONG! Punishment damage (45%)"
    else
        SpawnHarmlessGrayFly(player)
        feedback.text = "WRONG! Harmless gray fly (50%)"
    end
    player:AnimateSad()
    feedback.answer = "正确答案：" .. correctAnswer
    feedback.good = false
end

local function ResolveAnswer(selectedSlot)
    local ownerIndex = quiz.ownerIndex
    ReleaseRoom()
    quiz.active = false
    quiz.options = {}
    ResetQuizTimer()

    if ownerIndex < 0 or ownerIndex >= game:GetNumPlayers() then
        return
    end

    local player = Isaac.GetPlayer(ownerIndex)
    if selectedSlot == quiz.correctSlot then
        ApplyCorrectReward(player)
    else
        ApplyWrongPenalty(player, quiz.correctAnswer)
    end
    feedback.frames = FEEDBACK_FRAMES
end

local function ReadQuizInput()
    if quiz.inputLock > 0 then
        quiz.inputLock = quiz.inputLock - 1
        return nil
    end

    if Input.IsButtonTriggered(Keyboard.KEY_1, 0)
        or Input.IsButtonTriggered(Keyboard.KEY_KP_1, 0) then
        return 1
    end
    if Input.IsButtonTriggered(Keyboard.KEY_2, 0)
        or Input.IsButtonTriggered(Keyboard.KEY_KP_2, 0) then
        return 2
    end
    if Input.IsButtonTriggered(Keyboard.KEY_3, 0)
        or Input.IsButtonTriggered(Keyboard.KEY_KP_3, 0) then
        return 3
    end

    if quiz.ownerIndex >= 0 and quiz.ownerIndex < game:GetNumPlayers() then
        local controller = Isaac.GetPlayer(quiz.ownerIndex).ControllerIndex
        if Input.IsActionTriggered(ButtonAction.ACTION_SHOOTLEFT, controller) then
            return 1
        elseif Input.IsActionTriggered(ButtonAction.ACTION_SHOOTUP, controller) then
            return 2
        elseif Input.IsActionTriggered(ButtonAction.ACTION_SHOOTRIGHT, controller) then
            return 3
        end
    end
    return nil
end

function CET6Mod:OnGameStarted(isContinued)
    local startSeed = game:GetSeeds():GetStartSeed()
    rng:SetSeed(startSeed, isContinued and 61 or 35)
    outcomeRng:SetSeed(startSeed, isContinued and 73 or 47)
    quiz.active = false
    quiz.timer = nil
    quiz.frozen = {}
    feedback.frames = 0
end

function CET6Mod:OnUpdate()
    if feedback.frames > 0 then
        feedback.frames = feedback.frames - 1
    end

    if quiz.active then
        FreezeRoom()
        local selected = ReadQuizInput()
        if selected ~= nil then
            ResolveAnswer(selected)
        end
        return
    end

    local holders = GetItemHolders()
    if #holders == 0 then
        quiz.timer = nil
        return
    end

    if game:IsPaused() then
        return
    end

    if quiz.timer == nil then
        ResetQuizTimer()
    end

    quiz.timer = quiz.timer - 1
    if quiz.timer <= 0 then
        BeginQuiz(holders[RandomInt(1, #holders)])
    end
end

function CET6Mod:OnInputAction(entity, inputHook, buttonAction)
    if not quiz.active then
        return nil
    end

    if inputHook == InputHook.GET_ACTION_VALUE then
        return 0.0
    end
    return false
end

function CET6Mod:OnEntityDamage(entity, amount, damageFlags, source, countdownFrames)
    if quiz.active and entity:ToPlayer() ~= nil then
        return false
    end
    return nil
end

function CET6Mod:OnNewRoom()
    if quiz.active then
        ReleaseRoom()
        quiz.active = false
        ResetQuizTimer()
    end
end

function CET6Mod:OnPreItemTextDisplay(title, subtitle, isSticky, isCurseDisplay)
    if Options.Language ~= "zh" or isSticky or isCurseDisplay or ITEM_ID <= 0 then
        return nil
    end

    local config = Isaac.GetItemConfig():GetCollectible(ITEM_ID)
    if config ~= nil and title == config.Name and subtitle == config.Description then
        game:GetHUD():ShowItemText(ITEM_DISPLAY_NAME_ZH, subtitle)
        return false
    end
    return nil
end

function CET6Mod:OnExecuteCommand(command, parameters)
    local normalized = string.lower(command)
    if normalized == "cet6give" then
        if ITEM_ID > 0 then
            Isaac.GetPlayer(0):AddCollectible(ITEM_ID, 0, true)
            Isaac.ConsoleOutput("CET-6 Vocabulary Must-Learn granted.\n")
        end
    elseif normalized == "cet6quiz" then
        local holders = GetItemHolders()
        if #holders > 0 and not quiz.active then
            BeginQuiz(holders[1])
            Isaac.ConsoleOutput("CET-6 quiz started.\n")
        else
            Isaac.ConsoleOutput("Give the item first, or finish the current quiz.\n")
        end
    end
end

local function DrawCentered(text, y, color, scale)
    local screenWidth = Isaac.GetScreenWidth()
    local textWidth = uiFont:GetStringWidthUTF8(text) * scale
    local x = math.floor((screenWidth - textWidth) / 2 + 0.5)
    uiFont:DrawStringScaledUTF8(
        text,
        x,
        math.floor(y + 0.5),
        scale,
        scale,
        color,
        0,
        false
    )
end

function CET6Mod:OnRender()
    if feedback.frames > 0 then
        local feedbackColor = feedback.good
            and KColor(0.55, 1.0, 0.55, 1.0)
            or KColor(1.0, 0.45, 0.45, 1.0)
        DrawCentered(feedback.text, Isaac.GetScreenHeight() / 2 - 105, feedbackColor, 0.75)
        if feedback.answer ~= "" then
            DrawCentered(feedback.answer, Isaac.GetScreenHeight() / 2 - 88, KColor(1.0, 0.9, 0.45, 1.0), 0.85)
        end
    end

    if not quiz.active then
        return
    end

    local centerX = Isaac.GetScreenWidth() / 2
    local centerY = Isaac.GetScreenHeight() / 2
    panelSprite:Render(Vector(centerX, centerY), Vector.Zero, Vector.Zero)

    DrawCentered("六级单词测试", centerY - 73, KColor(0.95, 0.86, 0.36, 1.0), 1.0)
    DrawCentered("中文释义：" .. quiz.meaning, centerY - 45, KColor(1.0, 1.0, 1.0, 1.0), 0.85)
    DrawCentered("(" .. quiz.pinyin .. ")", centerY - 27, KColor(0.65, 0.78, 0.65, 1.0), 0.65)

    for slot = 1, 3 do
        DrawCentered(
            "[" .. slot .. "]  " .. quiz.options[slot],
            centerY - 3 + (slot - 1) * 29,
            KColor(0.88, 1.0, 0.88, 1.0),
            0.86
        )
    end

    DrawCentered("按 1 / 2 / 3 选择答案", centerY + 75, KColor(0.65, 0.65, 0.65, 1.0), 0.65)
end

uiFont:Load("font/cjk/lanapixel.fnt")
if not uiFont:IsLoaded() then
    uiFont:Load("font/terminus8.fnt")
end

panelSprite:Load("gfx/ui/cet6_panel.anm2", true)
panelSprite:Play("Idle", true)

CET6Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, CET6Mod.OnGameStarted)
CET6Mod:AddCallback(ModCallbacks.MC_POST_UPDATE, CET6Mod.OnUpdate)
CET6Mod:AddCallback(ModCallbacks.MC_INPUT_ACTION, CET6Mod.OnInputAction)
CET6Mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, CET6Mod.OnEntityDamage, EntityType.ENTITY_PLAYER)
CET6Mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, CET6Mod.OnNewRoom)
CET6Mod:AddCallback(ModCallbacks.MC_PRE_ITEM_TEXT_DISPLAY, CET6Mod.OnPreItemTextDisplay)
CET6Mod:AddCallback(ModCallbacks.MC_POST_RENDER, CET6Mod.OnRender)
CET6Mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, CET6Mod.OnExecuteCommand)
