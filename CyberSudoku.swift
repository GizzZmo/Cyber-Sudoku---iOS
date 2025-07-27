import SwiftUI
import CoreData
import Combine
import GameKit // Import GameKit for Game Center

// --- App Entry Point ---
@main
struct CyberSudokuApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            // The root view is now GameContainerView, which manages the overall game flow.
            GameContainerView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

// --- Core Data Persistence ---
struct PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "CyberSudoku")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}

// --- Game Center Manager ---
class GameCenterManager: NSObject, ObservableObject {
    static let shared = GameCenterManager()
    
    @Published var isAuthenticated = false
    
    private override init() {
        super.init()
    }
    
    /// Authenticates the local player with Game Center.
    func authenticateLocalPlayer() {
        let localPlayer = GKLocalPlayer.local
        localPlayer.authenticateHandler = { viewController, error in
            if let vc = viewController {
                // Present the Game Center login view controller if needed.
                self.getRootViewController()?.present(vc, animated: true, completion: nil)
                return
            }
            if let error = error {
                print("Game Center Error: \(error.localizedDescription)")
                self.isAuthenticated = false
                return
            }
            
            if localPlayer.isAuthenticated {
                print("Game Center: Player authenticated.")
                self.isAuthenticated = true
            } else {
                print("Game Center: Player not authenticated.")
                self.isAuthenticated = false
            }
        }
    }
    
    /// Submits a score to a specific leaderboard.
    /// - Parameters:
    ///   - score: The score value to submit. Note: Game Center leaderboards use Int64. Lower is better for time.
    ///   - leaderboardID: The unique identifier for the leaderboard.
    func submitScore(time: TimeInterval, leaderboardID: String) {
        guard isAuthenticated else {
            print("Cannot submit score, player not authenticated.")
            return
        }
        
        // Convert time to an integer format (e.g., hundredths of a second)
        // Lower scores are better, so this works directly with time.
        let scoreValue = Int64(time * 100)
        
        GKLeaderboard.submitScore(scoreValue, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [leaderboardID]) { error in
            if let error = error {
                print("Error submitting score to Game Center: \(error.localizedDescription)")
            } else {
                print("Successfully submitted score (\(scoreValue)) to leaderboard \(leaderboardID)")
            }
        }
    }
    
    /// Helper to get the root view controller to present the Game Center login screen.
    private func getRootViewController() -> UIViewController? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.rootViewController
    }
}


// --- Game Flow Management (FSM) ---
class GameFlowManager: ObservableObject {
    enum GameState { case playingSudoku, showingMiniGame }
    @Published var currentGameState: GameState = .playingSudoku
    func puzzleCompleted() { currentGameState = .showingMiniGame }
    func miniGameDismissed() { currentGameState = .playingSudoku }
}

// --- Models ---
struct SudokuCell: Identifiable, Equatable {
    let id = UUID()
    var value: Int?, notes: Set<Int> = [], isGiven: Bool, isHighlighted: Bool = false, isIncorrect: Bool = false
}
enum Difficulty: String, CaseIterable, Identifiable {
    case easy = "Easy", medium = "Medium", hard = "Hard", expert = "Expert"
    var id: String { self.rawValue }
    var emptyCells: Int {
        switch self { case .easy: 40; case .medium: 45; case .hard: 50; case .expert: 54 }
    }
}

// --- View Models ---
class SudokuBoardViewModel: ObservableObject {
    @Published var grid: [[SudokuCell]] = []
    @Published var selectedCell: (row: Int, col: Int)?
    @Published var timeElapsed: TimeInterval = 0
    @Published var isGenerating: Bool = false
    var onPuzzleComplete: (() -> Void)?
    private var currentDifficulty: Difficulty = .easy
    private var timer: Timer?
    private let generator = SudokuGenerator()
    init() { startNewGame(difficulty: .easy) }
    func startNewGame(difficulty: Difficulty) {
        currentDifficulty = difficulty; isGenerating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let newPuzzle = self.generator.generate(difficulty: difficulty)
            DispatchQueue.main.async {
                self.grid = self.createGrid(from: newPuzzle); self.selectedCell = nil
                self.resetTimer(); self.startTimer(); self.isGenerating = false
            }
        }
    }
    private func createGrid(from puzzle: [[Int]]) -> [[SudokuCell]] {
        puzzle.map { row in row.map { SudokuCell(value: $0 == 0 ? nil : $0, isGiven: $0 != 0) } }
    }
    private func checkCompletion() {
        if grid.allSatisfy({ row in row.allSatisfy { $0.value != nil && !$0.isIncorrect } }) {
            stopTimer(); onPuzzleComplete?()
        }
    }
    func saveScore(context: NSManagedObjectContext) {
        let newScore = Score(context: context)
        newScore.id = UUID(); newScore.date = Date(); newScore.timeElapsed = self.timeElapsed
        newScore.difficulty = self.currentDifficulty.rawValue; try? context.save()
    }
    func selectCell(row: Int, col: Int) { if !grid[row][col].isGiven { selectedCell = (row, col); highlightCells(row: row, col: col) } else { selectedCell = nil } }
    func enterValue(_ value: Int) { guard let sel = selectedCell else { return }; grid[sel.row][sel.col].notes.removeAll(); grid[sel.row][sel.col].value = value; validateBoard(); checkCompletion() }
    func toggleNote(_ value: Int) { guard let sel = selectedCell else { return }; grid[sel.row][sel.col].value = nil; if grid[sel.row][sel.col].notes.contains(value) { grid[sel.row][sel.col].notes.remove(value) } else { grid[sel.row][sel.col].notes.insert(value) } }
    func clearSelectedCell() { guard let sel = selectedCell else { return }; grid[sel.row][sel.col].value = nil; grid[sel.row][sel.col].notes.removeAll(); grid[sel.row][sel.col].isIncorrect = false; validateBoard() }
    private func validateBoard() { for r in 0..<9 { for c in 0..<9 { grid[r][c].isIncorrect = false }}; for r in 0..<9 { for c in 0..<9 { if let val = grid[r][c].value, !grid[r][c].isGiven { if !isPlacementValid(value: val, row: r, col: c) { grid[r][c].isIncorrect = true }}}} }
    private func isPlacementValid(value: Int, row: Int, col: Int) -> Bool { for c in 0..<9 { if c != col, grid[row][c].value == value { return false } }; for r in 0..<9 { if r != row, grid[r][col].value == value { return false } }; let sr = (row/3)*3, sc = (col/3)*3; for r in sr..<(sr+3) { for c in sc..<(sc+3) { if r != row, c != col, grid[r][c].value == value { return false } } }; return true }
    private func highlightCells(row: Int, col: Int) { for r in 0..<9 { for c in 0..<9 { grid[r][c].isHighlighted = false }}; for i in 0..<9 { grid[row][i].isHighlighted = true; grid[i][col].isHighlighted = true }; let sr = (row/3)*3, sc = (col/3)*3; for r in sr..<(sr+3) { for c in sc..<(sc+3) { grid[r][c].isHighlighted = true } } }
    private func startTimer() { timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.timeElapsed += 1 } }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func resetTimer() { stopTimer(); timeElapsed = 0 }
}

// --- Views ---
struct GameContainerView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var gameFlow = GameFlowManager()
    @StateObject private var sudokuViewModel = SudokuBoardViewModel()
    @StateObject private var gameCenterManager = GameCenterManager.shared
    @State private var selectedDifficulty: Difficulty = .easy
    
    // *** IMPORTANT: Replace with your actual leaderboard ID from App Store Connect ***
    private let leaderboardID = "com.cybersudoku.leaderboard.besttimes"
    
    var body: some View {
        SudokuBoardView(viewModel: sudokuViewModel, selectedDifficulty: $selectedDifficulty)
            .onAppear {
                sudokuViewModel.onPuzzleComplete = {
                    // Save to Core Data
                    sudokuViewModel.saveScore(context: viewContext)
                    // Submit to Game Center
                    gameCenterManager.submitScore(time: sudokuViewModel.timeElapsed, leaderboardID: leaderboardID)
                    // Trigger mini-game
                    gameFlow.puzzleCompleted()
                }
                // Authenticate with Game Center when the app appears
                gameCenterManager.authenticateLocalPlayer()
            }
            .fullScreenCover(isPresented: .constant(gameFlow.currentGameState == .showingMiniGame)) {
                MemoryGameView {
                    gameFlow.miniGameDismissed()
                    sudokuViewModel.startNewGame(difficulty: selectedDifficulty)
                }
            }
    }
}

struct SudokuBoardView: View {
    @ObservedObject var viewModel: SudokuBoardViewModel
    @Binding var selectedDifficulty: Difficulty
    @State private var isNoteMode = false
    @State private var showingHighScores = false

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 15) {
                    HStack {
                        Text("Cyber Sudoku").font(.largeTitle).fontWeight(.bold).lineLimit(1).minimumScaleFactor(0.5)
                        Spacer()
                        Button(action: { showingHighScores = true }) { Image(systemName: "trophy.fill").font(.title2) }
                    }.padding(.horizontal)
                    HStack {
                        Picker("Difficulty", selection: $selectedDifficulty) {
                            ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Button(action: { viewModel.startNewGame(difficulty: selectedDifficulty) }) {
                            Image(systemName: "arrow.clockwise.circle.fill"); Text("New")
                        }.padding(.leading, 10)
                    }.padding(.horizontal)
                    SudokuGridView(grid: viewModel.grid, selectedCell: viewModel.selectedCell) { r, c in viewModel.selectCell(row: r, col: c) }
                        .padding(.horizontal).aspectRatio(1.0, contentMode: .fit)
                    TimerView(timeElapsed: viewModel.timeElapsed)
                    InputPadView(isNoteMode: $isNoteMode) { v in if isNoteMode { viewModel.toggleNote(v) } else { viewModel.enterValue(v) } }
                        onClear: { viewModel.clearSelectedCell() }.padding(.horizontal)
                }
                .navigationBarHidden(true)
                .sheet(isPresented: $showingHighScores) { HighScoresView() }
                if viewModel.isGenerating {
                    VStack { ProgressView().scaleEffect(2); Text("Generating...").padding(.top) }
                    .padding(30).background(.black.opacity(0.7)).cornerRadius(20).foregroundColor(.white)
                }
            }
        }.navigationViewStyle(.stack)
    }
}

// --- Mini-Game: Memory Sequence ---
struct MemoryGameView: View {
    @State private var sequence = [Int](), playerInput = [Int](), activeIndex: Int?, level = 1
    @State private var message = "Tap Start to Play!", isPlayerTurn = false, buttonsDisabled = true
    var onDismiss: () -> Void
    let columns: [GridItem] = Array(repeating: .init(.flexible()), count: 3)
    var body: some View {
        ZStack {
            RadialGradient(gradient: Gradient(colors: [.blue, .black]), center: .center, startRadius: 2, endRadius: 650).ignoresSafeArea()
            VStack(spacing: 30) {
                Text("Memory Challenge").font(.largeTitle).fontWeight(.bold)
                Text(message).font(.title2).fontWeight(.medium)
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(0..<9) { index in
                        Button(action: { playerTapped(index) }) {
                            Rectangle().fill(activeIndex == index ? .yellow : .blue.opacity(0.6))
                                .aspectRatio(1, contentMode: .fit).cornerRadius(15)
                                .shadow(color: .blue.opacity(0.5), radius: 5, x: 0, y: 5)
                        }.disabled(buttonsDisabled)
                    }
                }.padding()
                if isPlayerTurn { Button("Done Playing", action: onDismiss).font(.headline).padding().background(.red).cornerRadius(10) }
                else { Button(action: startGame) { Text(level == 1 ? "Start" : "Next Level").font(.headline).padding().background(.green).cornerRadius(10) } }
            }.padding().foregroundColor(.white)
        }
    }
    func startGame() { playerInput = []; sequence.append(Int.random(in: 0..<9)); message = "Watch..."; buttonsDisabled = true; playSequence() }
    func playSequence() { var delay: Double = 0; for (i, idx) in sequence.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { activeIndex = idx }; delay += 0.7; DispatchQueue.main.asyncAfter(deadline: .now() + delay) { activeIndex = nil; if i == sequence.count - 1 { isPlayerTurn = true; buttonsDisabled = false; message = "Your turn!" } }; delay += 0.3 } }
    func playerTapped(_ index: Int) {
        guard isPlayerTurn else { return }; playerInput.append(index)
        if playerInput.last != sequence[playerInput.count - 1] {
            message = "Wrong! Game Over. Level: \(level)"; isPlayerTurn = false; buttonsDisabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { onDismiss() }
        } else if playerInput.count == sequence.count {
            message = "Correct! Tap for Next Level"; level += 1; isPlayerTurn = false; buttonsDisabled = true
        }
    }
}

// --- Other Views (HighScores, Grid, Cells, etc.) ---
struct HighScoresView: View {
    @Environment(\.managedObjectContext) private var viewContext; @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Score.timeElapsed, ascending: true)], animation: .default) private var scores: FetchedResults<Score>
    var body: some View { NavigationView { VStack { if scores.isEmpty { Text("No high scores yet!").padding() } else { List { ForEach(scores) { score in HStack { VStack(alignment: .leading) { Text(score.difficulty ?? "N/A").font(.headline); Text(score.date ?? Date(), formatter: itemFormatter).font(.caption).foregroundColor(.secondary) }; Spacer(); Text(formatTime(score.timeElapsed)).font(.title2).fontWeight(.semibold) } }.onDelete(perform: deleteItems) } } }.navigationTitle("High Scores").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }; ToolbarItem(placement: .navigationBarLeading) { EditButton() } } } }
    private func deleteItems(offsets: IndexSet) { withAnimation { offsets.map { scores[$0] }.forEach(viewContext.delete); try? viewContext.save() } }
}
private let itemFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f }()
func formatTime(_ interval: TimeInterval) -> String { String(format: "%02d:%02d", Int(interval)/60, Int(interval)%60) }
struct SudokuGridView: View { let grid: [[SudokuCell]]; let selectedCell: (row: Int, col: Int)?; let onCellTapped: (Int, Int) -> Void; var body: some View { VStack(spacing: 0) { ForEach(0..<9, id: \.self) { row in HStack(spacing: 0) { ForEach(0..<9, id: \.self) { col in SudokuCellView(cell: grid[row][col], isSelected: selectedCell?.row == row && selectedCell?.col == col).onTapGesture { onCellTapped(row, col) }; if col==2||col==5{Divider().background(Color.primary).frame(width:2)} } }; if row==2||row==5{Divider().background(Color.primary).frame(height:2)} } }.background(Color(.systemBackground)).border(Color.primary, width: 2) } }
struct SudokuCellView: View { let cell: SudokuCell; let isSelected: Bool; var body: some View { ZStack { Rectangle().fill(backgroundColor).aspectRatio(1.0, contentMode: .fit); if let value = cell.value { Text("\(value)").font(.title2).fontWeight(cell.isGiven ? .bold : .regular).foregroundColor(cell.isIncorrect ? .red : .primary) } else { NoteGridView(notes: cell.notes) } }.border(Color.secondary.opacity(0.5), width: 0.5) }; private var backgroundColor: Color { if isSelected { .blue.opacity(0.4) } else if cell.isHighlighted { .blue.opacity(0.2) } else { Color(.systemBackground) } } }
struct NoteGridView: View { let notes: Set<Int>; private let columns: [GridItem] = Array(repeating: .init(.flexible()), count: 3); var body: some View { LazyVGrid(columns: columns, spacing: 0) { ForEach(1...9, id: \.self) { number in Text(notes.contains(number) ? "\(number)" : " ").font(.system(size: 10)).minimumScaleFactor(0.8).frame(maxWidth: .infinity, maxHeight: .infinity) } }.padding(1) } }
struct InputPadView: View { @Binding var isNoteMode: Bool; let onNumberTapped: (Int) -> Void; let onClear: () -> Void; var body: some View { VStack(spacing: 5) { HStack(spacing: 10) { ForEach(1...9, id: \.self) { num in Button(action: { onNumberTapped(num) }) { Text("\(num)").font(.title2).frame(maxWidth: .infinity).padding(.vertical, 8).background(Color.blue.opacity(0.2)).cornerRadius(8) } } }; HStack { Button(action: { isNoteMode.toggle() }) { Image(systemName: isNoteMode ? "pencil.circle.fill" : "pencil.circle"); Text("Notes") }.font(.headline).padding(); Spacer(); Button(action: onClear) { Image(systemName: "trash"); Text("Clear") }.font(.headline).padding() } } } }
struct TimerView: View { let timeElapsed: TimeInterval; var body: some View { HStack { Image(systemName: "timer"); Text(formatTime(timeElapsed)) }.font(.headline).padding(8).background(Color.secondary.opacity(0.2)).cornerRadius(10) } }

// --- AI & Generation Logic ---
struct SudokuGenerator {
    private var board: [[Int]]; private var solutionCount: Int
    init() { self.board = Array(repeating: Array(repeating: 0, count: 9), count: 9); self.solutionCount = 0 }
    mutating func generate(difficulty: Difficulty) -> [[Int]] { board = Array(repeating: Array(repeating: 0, count: 9), count: 9); fill(board: &board); var puzzle = board; let cellsToRemove = difficulty.emptyCells; var removedCount = 0; var positions = (0..<81).map { ($0/9, $0%9) }.shuffled(); while removedCount < cellsToRemove && !positions.isEmpty { let (row, col) = positions.removeLast(); let val = puzzle[row][col]; if val != 0 { puzzle[row][col] = 0; var tempBoard = puzzle; solutionCount = 0; countSolutions(board: &tempBoard); if solutionCount != 1 { puzzle[row][col] = val } else { removedCount += 1 } } }; return puzzle }
    @discardableResult private func fill(board: inout [[Int]]) -> Bool { if let (r, c) = findEmpty(in: board) { for num in (1...9).shuffled() { if isSafe(board: board, row: r, col: c, num: num) { board[r][c] = num; if fill(board: &board) { return true }; board[r][c] = 0 } }; return false }; return true }
    private mutating func countSolutions(board: inout [[Int]]) { if let (r, c) = findEmpty(in: board) { for num in 1...9 { if isSafe(board: board, row: r, col: c, num: num) { board[r][c] = num; countSolutions(board: &board); if solutionCount > 1 { return }; board[r][c] = 0 } }; return }; solutionCount += 1 }
    private func findEmpty(in board: [[Int]]) -> (Int, Int)? { for r in 0..<9 { for c in 0..<9 { if board[r][c] == 0 { return (r, c) } } }; return nil }
    private func isSafe(board: [[Int]], row: Int, col: Int, num: Int) -> Bool { for c in 0..<9 { if board[row][c] == num { return false } }; for r in 0..<9 { if board[r][col] == num { return false } }; let sr = row - row % 3, sc = col - col % 3; for r in 0..<3 { for c in 0..<3 { if board[r + sr][c + sc] == num { return false } } }; return true }
}
