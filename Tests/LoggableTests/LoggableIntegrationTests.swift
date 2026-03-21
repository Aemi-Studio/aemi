import Loggable
import Testing

// MARK: - Test Types

@Loggable
struct PlainStruct {
    func doWork() {
        logger.info("Working")
    }
}

@Loggable
public struct PublicStruct {
    public func doWork() {
        logger.info("Working")
    }
}

@Loggable
class PlainClass {
    func doWork() {
        logger.info("Working")
    }
}

@Loggable
public class PublicClass {
    public func doWork() {
        logger.info("Working")
    }
}

@Loggable
actor PlainActor {
    func doWork() {
        logger.info("Working")
    }

    nonisolated func doNonisolatedWork() {
        logger.info("Nonisolated working")
    }
}

@Loggable
public actor PublicActor {
    public func doWork() {
        logger.info("Working")
    }

    nonisolated public func doNonisolatedWork() {
        logger.info("Nonisolated working")
    }
}

@Loggable
enum PlainEnum {
    case a
    case b
}

@Loggable
public enum PublicEnum {
    case a
    case b
}

@Loggable
private struct PrivateStruct {
    func doWork() {
        logger.info("Working")
    }
}

@Loggable
fileprivate class FileprivateClass {
    func doWork() {
        logger.info("Working")
    }
}

@Loggable
struct GenericStruct<T: Codable> {
    let value: T

    func doWork() {
        logger.info("Working with generic")
    }
}

@Loggable
actor GenericActor<T: Sendable> {
    func doWork() {
        logger.info("Working with generic actor")
    }
}

// MARK: - Struct Tests

@Suite("Struct Integration")
struct StructIntegrationTests {
    @Test("Static logger accessible on plain struct")
    func plainStructStaticLogger() {
        let logger = PlainStruct.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Instance logger accessible on plain struct")
    func plainStructInstanceLogger() {
        let instance = PlainStruct()
        #expect(type(of: instance.logger) == Logger.self)
    }

    @Test("Public struct logger is accessible")
    func publicStructLogger() {
        _ = PublicStruct.logger
        let instance = PublicStruct()
        _ = instance.logger
    }

    @Test("Private struct logger works internally via method")
    func privateStructLogger() {
        let instance = PrivateStruct()
        instance.doWork()
    }
}

// MARK: - Class Tests

@Suite("Class Integration")
struct ClassIntegrationTests {
    @Test("Static logger accessible on plain class")
    func plainClassStaticLogger() {
        let logger = PlainClass.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Instance logger accessible on plain class")
    func plainClassInstanceLogger() {
        let instance = PlainClass()
        #expect(type(of: instance.logger) == Logger.self)
    }

    @Test("Public class logger is accessible")
    func publicClassLogger() {
        _ = PublicClass.logger
        let instance = PublicClass()
        _ = instance.logger
    }

    @Test("Fileprivate class logger works internally")
    func fileprivateClassLogger() {
        _ = FileprivateClass.logger
        let instance = FileprivateClass()
        _ = instance.logger
    }
}

// MARK: - Actor Tests

@Suite("Actor Integration")
struct ActorIntegrationTests {
    @Test("Static logger accessible on plain actor")
    func plainActorStaticLogger() {
        let logger = PlainActor.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Instance logger accessible without await (nonisolated)")
    func plainActorInstanceLogger() {
        let instance = PlainActor()
        let logger = instance.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Public actor logger is accessible")
    func publicActorLogger() {
        _ = PublicActor.logger
        let instance = PublicActor()
        _ = instance.logger
    }
}

// MARK: - Enum Tests

@Suite("Enum Integration")
struct EnumIntegrationTests {
    @Test("Static logger accessible on plain enum")
    func plainEnumStaticLogger() {
        let logger = PlainEnum.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Instance logger accessible on enum case")
    func plainEnumInstanceLogger() {
        let value = PlainEnum.a
        let logger = value.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Public enum logger is accessible")
    func publicEnumLogger() {
        _ = PublicEnum.logger
        let value = PublicEnum.b
        _ = value.logger
    }
}

// MARK: - Generic Tests

@Suite("Generic Integration")
struct GenericIntegrationTests {
    @Test("Static logger accessible on generic struct")
    func genericStructStaticLogger() {
        let logger = GenericStruct<Int>.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Instance logger accessible on generic struct")
    func genericStructInstanceLogger() {
        let instance = GenericStruct(value: 42)
        #expect(type(of: instance.logger) == Logger.self)
    }

    @Test("Static logger accessible on generic actor")
    func genericActorStaticLogger() {
        let logger = GenericActor<Int>.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Instance logger accessible on generic actor without await")
    func genericActorInstanceLogger() {
        let instance = GenericActor<Int>()
        let logger = instance.logger
        #expect(type(of: logger) == Logger.self)
    }

    @Test("Generic type can log without crashing")
    func genericLogging() {
        GenericStruct<String>.logger.info("Generic struct logging")
        GenericActor<Int>.logger.debug("Generic actor logging")
    }
}

// MARK: - Cross-Cutting Tests

@Suite("Cross-Cutting")
struct CrossCuttingTests {
    @Test("Logger can be used for logging without crashing")
    func loggerWorks() {
        PlainStruct.logger.info("Test message from struct")
        PlainClass.logger.debug("Debug message from class")
        PlainActor.logger.error("Error message from actor")
        PlainEnum.logger.warning("Warning message from enum")
    }

    @Test("Instance and static logger usage in methods")
    func usageInMethods() {
        let s = PlainStruct()
        s.doWork()

        let c = PlainClass()
        c.doWork()
    }

    @Test("Nonisolated method on actor can use logger")
    func actorNonisolatedMethod() {
        let a = PlainActor()
        a.doNonisolatedWork()

        let pa = PublicActor()
        pa.doNonisolatedWork()
    }
}
