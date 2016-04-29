require 'optim'
require 'CTCCriterion'
require 'BRNN'
require 'ctchelpers'
require 'gnuplot'
require 'xlua'
local WERCalculator = require 'WERCalculator'

local Network = {}
local logger = optim.Logger('train.log')
logger:setNames { 'loss', 'WER' }
logger:style{'-', '-'}

function Network:init(networkParams)
    self.loadModel = networkParams.loadModel or false -- Set to true to load the model into Network.
    self.saveModel = networkParams.saveModel or false -- Set to true if you want to save the model after training.
    self.fileName = networkParams.fileName -- The file name to save/load the network from.
    self.gpu = networkParams.gpu or false -- Set to true to use GPU.
    self.model = nil
    if (self.gpu) then -- Load gpu modules.
    require 'cunn'
    require 'cudnn'
    end
    if (self.loadModel) then
        assert(networkParams.fileName, "Filename hasn't been given to load model.")
        self:loadNetwork(networkParams.fileName)
    else
        assert(networkParams.model, "Must have given a model to train.")
        self:prepSpeechModel(networkParams.model)
    end
    assert((networkParams.saveModel or networkParams.loadModel) and networkParams.fileName, "To save/load you must specify the fileName you want to save to")
end

function Network:prepSpeechModel(model)
    if (self.gpu) then model:cuda() end
    model:training()
    self.model = model
end

-- Returns a prediction of the input net and input tensors.
function Network:predict(inputTensors)
    local prediction = self.model:forward(inputTensors)
    return prediction
end

local function WERValidationSet(self, validationSet)
    if(validationSet) then
        self.model:evaluate()
        local wer =  WERCalculator.calculateWordErrorRate(false, validationSet, nil, self.model, self.gpu)
        self.model:zeroGradParameters()
        self.model:training()
        return wer
    end
end

--Trains the network using SGD and the defined feval.
--Uses warp-ctc cost evaluation.
function Network:trainNetwork(dataset, validationDataset, epochs, sgd_params)
    local lossHistory = {}
    local validationHistory = {}
    local ctcCriterion = nn.CTCCriterionTest()

    local x, gradParameters = self.model:getParameters()

    -- inputs (preallocate)
    local inputs = torch.Tensor()
    if self.gpu then
        ctcCriterion = nn.CTCCriterionTest():cuda()
        inputs = inputs:cuda()
    end

    local function feval(x_new)
        local inputsCPU, targets = dataset:nextData()
        -- transfer over to GPU
        inputs:resize(inputsCPU:size()):copy(inputsCPU)
        gradParameters:zero()
        local predictions = self.model:forward(inputs)
        local loss = ctcCriterion:forward(predictions, targets)
        self.model:zeroGradParameters()
        local gradOutput = ctcCriterion:backward(predictions, targets)
        self.model:backward(inputs, gradOutput)
        return loss, gradParameters
    end

    local currentLoss
    local startTime = os.time()
    local dataSetSize = dataset:size()
    for i = 1, epochs do
        local averageLoss = 0
        print(string.format("Training Epoch: %d", i))

        local wer = WERValidationSet(self, validationDataset)
        if wer then table.insert(validationHistory, wer) end

        for j = 1, dataSetSize do
            currentLoss = 0
            local _, fs = optim.sgd(feval, x, sgd_params)
            currentLoss = currentLoss + fs[1]
            xlua.progress(j, dataSetSize)
            averageLoss = averageLoss + currentLoss
        end

        averageLoss = averageLoss / dataSetSize -- Calculate the average loss at this epoch.
        table.insert(lossHistory, averageLoss) -- Add the average loss value to the logger.
        print(string.format("Training Epoch: %d Average Loss: %f", i, averageLoss))

        logger:add{averageLoss, wer}
    end
    local endTime = os.time()
    local secondsTaken = endTime - startTime
    local minutesTaken = secondsTaken / 60
    print("Minutes taken to train: ", minutesTaken)

    if (self.saveModel) then
        print("Saving model")
        self:saveNetwork(self.fileName)
    end
    return lossHistory, validationHistory, minutesTaken
end


function Network:createLossGraph()
    logger:plot()
end


function Network:saveNetwork(saveName)
    torch.save(saveName, self.model)
end

--Loads the model into Network.
function Network:loadNetwork(saveName)
    local model = torch.load(saveName)
    self.model = model
    model:evaluate()
end

return Network